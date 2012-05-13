#include "USBMicroX.h"
#define UNLESS(S) if(!(S))

#define USBMX_ID_PRODUCT 0x01A5
#define USBMX_ID_VENDOR 0x0DE7

static long dict_get_long(CFDictionaryRef properties, CFStringRef key)
{
	long number;
	CFTypeRef value = CFDictionaryGetValue(properties, key);
	if (!value) return 0;
	CFTypeID type = CFGetTypeID(value);
	if (type != CFNumberGetTypeID()) return 0 ;
	CFNumberGetValue((CFNumberRef)value, kCFNumberLongType, (void *)&number);
	return number;
}

static char* dict_get_string(CFDictionaryRef properties, CFStringRef key, CFStringEncoding encoding)
{
	static char cstring[512];
	CFTypeRef value = CFDictionaryGetValue(properties, key);
	if (!value) return "";
	CFTypeID type = CFGetTypeID(value) ;
	if (type != CFStringGetTypeID()) return "";	
	CFStringGetCString((CFStringRef)value, cstring, sizeof(cstring), encoding);
	return cstring; // WARNING: be sure to copy string after return
}

static void nsp(int L) {
	int i = 0;
	while(i++ < L) printf("    ");
}

static void cftype_dump(CFTypeRef o, int L);

static void cftype_dump_arrayapply(const void *value, void *context) {
	int L = (int)context;
	nsp(L); printf("0x%08x\n", value);
	cftype_dump((CFTypeRef)value, L+1);
}

static void cftype_dump_dictapply (const void *key, const void *value, void *context) {
	int L = (int)context;
	nsp(L); printf("\"%s\" => 0x%08x\n",
		CFStringGetCStringPtr(key, CFStringGetSystemEncoding()), value);
	cftype_dump((CFTypeRef)value, L+1);
}

static void cftype_dump(CFTypeRef o, int L)
{
	if(CFGetTypeID(o) == CFArrayGetTypeID()) {
		nsp(L); printf("[\n");
		CFArrayApplyFunction(
			o,
			CFRangeMake(0, CFArrayGetCount(o)),
			cftype_dump_arrayapply,
			(void*)(L+1));
		nsp(L); printf("]\n");
	} else if(CFGetTypeID(o) == CFDictionaryGetTypeID()) {
		nsp(L); printf("{\n");
		CFDictionaryApplyFunction(
			o,
			cftype_dump_dictapply,
			(void*)(L+1));
		nsp(L); printf("}\n");
	} else if(CFGetTypeID(o) == CFNumberGetTypeID()) {
		long number;
		CFNumberGetValue((CFNumberRef)o, kCFNumberLongType, (void*)&number);
		nsp(L); printf("number: 0x%08x\n", number);
	} else if(CFGetTypeID(o) == CFStringGetTypeID()) {
		const char *s = CFStringGetCStringPtr(o, CFStringGetSystemEncoding());
		nsp(L); printf("string: \"%s\"\n", s);
	} else if(CFGetTypeID(o) == CFBooleanGetTypeID()) {
		nsp(L); printf("boolean: %s\n", CFBooleanGetValue(o)?"TRUE":"FALSE");		
	} else {
		nsp(L); printf("??? unknown type\n");
	}
}

int USBmX_DeviceAddedHandler(
			USBmX_ContextRef ctx, 
			USBmX_DeviceAddedProc proc, 
			void *cookie)
{
	ctx->deviceAdded = proc;
	ctx->deviceAdded_cookie = cookie;
	return 0;
}

int USBmX_DeviceRemovedHandler(
			USBmX_ContextRef ctx, 
			USBmX_DeviceRemovedProc proc, 
			void *cookie)
{
	ctx->deviceRemoved = proc;
	ctx->deviceRemoved_cookie = cookie;
	return 0;	
}

int USBmX_DeviceInfo(USBmX_DeviceRef dev)
{
	if(!dev) goto err;
	cftype_dump(dev->properties, 0);
	return 0;
err:
	return -1;
}

static void DumpBuffer(const u_char buf[], unsigned int buf_size)
{
	const u_char *p = buf;
	while(buf_size--) printf("0x%02x ", *p++);
	printf("\n");
}

void USBmX_DumpCommand(u_char buf[])
{
	DumpBuffer(buf, 8);
}

void DeviceAddedHandler(void *refCon, io_iterator_t iterator)
{
	#if USBMX_DEBUG_LOG
	USBMX_LOG("Device added notification");
	#endif
	io_object_t o;
	USBmX_ContextRef ctx;
	// Must iterate in order to re-arm notification
	while(o = IOIteratorNext(iterator)) {
		IOObjectRelease(o);
	}
	ctx = (USBmX_ContextRef)refCon;
	#if USBMX_DEBUG_LOG
	USBMX_LOG("ctx = %x", ctx);
	#endif
	USBmX_ScanForDevices(ctx);
}

void DestroyDeviceRef(USBmX_DeviceRef d)
{
	#if USBMX_DEBUG_LOG
	USBMX_LOG("Destroying: %x %x %x %x", d->properties, d->serialNumber, d->interface, d);
	#endif
	CFRelease(d->properties);
	free((void *)d->serialNumber);
	free((void *)d->deviceName);
	free((void *)d->manufacturer);
	(*d->interface)->close(d->interface);
	free(d);
}

void DeviceRemovedHandler(void *target, IOReturn result, void *refcon, void *sender)
{
	USBmX_DeviceRef d = (USBmX_DeviceRef)refcon;
	USBmX_ContextRef ctx = d->ctx;
	#if USBMX_DEBUG_LOG
	USBMX_LOG("Device Removed (# %s)", d->serialNumber);
	#endif
		
	USBmX_DeviceRef p = ctx->deviceList;
	USBmX_DeviceRef pl = NULL;
	while(p) {
		if(p == d)
		{
			if(pl == NULL)	ctx->deviceList = d->next;
			else			pl->next = d->next;
			////////////////////////////
			//USBMX_LOG("NEED TO CALL DEVICE REMOVED CALLBACK");
			if(ctx->deviceRemoved)
			{
				(*ctx->deviceRemoved)(d, ctx->deviceRemoved_cookie);
			}
			////////////////////////////
			DestroyDeviceRef(d);
			break;
		}
		pl = p;
		p = p->next;
	}
}

static void InterruptReportHandler(
	void *target, 
	IOReturn result, 
	void *refcon, 
	void *sender, 
	UInt32 bufferSize)
{
	USBmX_DeviceRef d = (USBmX_DeviceRef)target;

	#if USBMX_DEBUG_LOG
	printf("Response: ");
	DumpBuffer(d->response_buffer, bufferSize);
	#endif
	
	d->response_ready = 1;
}

static int SetReport(USBmX_DeviceRef d, const u_char *buf, unsigned int buf_size)
{
	#if USBMX_DEBUG_LOG
	printf("Report: "); DumpBuffer(buf, buf_size);
	#endif
	d->response_ready = 0;
	IOReturn rc = (*d->interface)->setReport(
		d->interface, 
		kIOHIDReportTypeFeature,
		0, //reportID
		(void *)buf,
		buf_size,
		1000, //timeout
		NULL,
		NULL,
		NULL
		);
	while(!d->response_ready) {
		SInt32 r = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, false);
		#if USBMX_DEBUG_LOG
		printf("wait r=%x\n", r);
		#endif
	}
	if(rc != kIOReturnSuccess) {
		USBMX_LOG("SetReport: (*interface)->setReport() Error %x", rc);
		return -1;
	}
	return 0;
}

int USBmX_DeviceCount(USBmX_ContextRef ctx)
{
	if(!ctx) return 0;
	USBmX_DeviceRef d = ctx->deviceList;
	int count = 0;
	while(d) {
		++count;
		d = d->next;
	}
	return count;
}

USBmX_DeviceRef USBmX_DefaultDevice(USBmX_ContextRef ctx)
{
	if(ctx) return ctx->deviceList;
	return NULL;
}

USBmX_DeviceRef USBmX_DeviceWithSerial(USBmX_ContextRef ctx, const char *serial)
{
	if(!ctx || !serial) return NULL;
	USBmX_DeviceRef dev = ctx->deviceList;
	#if USBMX_DEBUG_LOG
	USBMX_LOG("Searching for device...");
	#endif
	while(dev) {
		if(!strcmp(serial, dev->serialNumber))
		{
			#if USBMX_DEBUG_LOG
			USBMX_LOG("Device found! %x (# %s)", dev, dev->serialNumber);
			#endif			
			return dev;
		}
		dev = dev->next;
	}
	#if USBMX_DEBUG_LOG
	USBMX_LOG("Device not found");
	#endif
	return NULL;
}

int USBmX_RawCommand(USBmX_DeviceRef dev, 
	const u_char command[8], 
	u_char response[8])
{
	if(!dev) goto err;
	if(SetReport(dev, command, 8) < 0) goto err;
	if(response) {
		memcpy(response, dev->response_buffer, 8);
	}
	return 0;
err:
	return -1;
}

static int CreateDeviceRef(USBmX_ContextRef ctx, io_object_t dev, USBmX_DeviceRef *dev_out)
{
	IOReturn rc;
	kern_return_t result;

	USBmX_DeviceRef dr = USBMX_ALLOC(USBmX_Device);
	dr->next = NULL;
	dr->ctx = ctx;
	dr->userData = NULL;
	
	// Get device properties
	result = IORegistryEntryCreateCFProperties(
		dev, &dr->properties,
		kCFAllocatorDefault, kNilOptions);
	if(result != KERN_SUCCESS || !dr->properties) {
		USBMX_LOG("IORegistryEntryCreateCFProperties Error %x", result);			
		goto err;
	}

	dr->serialNumber = strdup(
		dict_get_string(
			dr->properties,
			CFSTR(kIOHIDSerialNumberKey), 
			CFStringGetSystemEncoding()));
	dr->deviceName = strdup(
		dict_get_string(
			dr->properties,
			CFSTR(kIOHIDProductKey), 
			CFStringGetSystemEncoding()));
	dr->manufacturer = strdup(
		dict_get_string(
			dr->properties,
			CFSTR(kIOHIDManufacturerKey), 
			CFStringGetSystemEncoding()));

	// Add device to head of list if we don't already have it
	if(USBmX_DeviceWithSerial(ctx, dr->serialNumber) == NULL)
	{
		#if USBMX_DEBUG_LOG
		USBMX_LOG("Adding device");
		#endif
		dr->next = ctx->deviceList;
		ctx->deviceList = dr;
	} else {
		#if USBMX_DEBUG_LOG
		USBMX_LOG("Already have device");
		#endif
		return 0;
	}

	#if USBMX_DEBUG_LOG
	USBMX_LOG("Found Device (# %s)", dr->serialNumber);
	USBMX_LOG("kIOHIDManufacturerKey: \"%s\"",
		dict_get_string(dr->properties, 
		CFSTR(kIOHIDManufacturerKey), CFStringGetSystemEncoding()));
	#endif

	{	// Set up the device
		SInt32 score = 0;
		IOCFPlugInInterface **plugIn;

		if((rc = IOCreatePlugInInterfaceForService(
			dev,
			kIOHIDDeviceUserClientTypeID,
			kIOCFPlugInInterfaceID,
			&plugIn, &score)) != kIOReturnSuccess)
		{
				USBMX_LOG("IOCreatePlugInInterfaceForService Error %x", rc);
				goto err;
		}
		
		// Grab interface
		IOHIDDeviceInterface **interface;
		HRESULT prc;
		prc = (*plugIn)->QueryInterface(plugIn,
			CFUUIDGetUUIDBytes(kIOHIDDeviceInterfaceID),
			(LPVOID)&interface);
		(*plugIn)->Release(plugIn);
		if(prc != S_OK) {
			USBMX_LOG("QueryInterface Error %x", prc);
			goto err;
		}
		
		dr->interface = interface;

		// Set up removal callback
		if((rc = (*interface)->setRemovalCallback(interface, 
			DeviceRemovedHandler, NULL, (void *)dr)) != kIOReturnSuccess)
		{
			USBMX_LOG("(*interface)->setRemovalCallback() Error %x", rc);
			goto err1;
		}

		if((rc = (*interface)->open(interface, 0)) != kIOReturnSuccess)
		{
			USBMX_LOG("(*interface)->open() Error %x", rc);
			goto err1;
        }

		mach_port_t async_port;
		if((rc = (*interface)->createAsyncPort(interface, &async_port)) != kIOReturnSuccess)
		{
			USBMX_LOG("(*interface)->createAsyncPort() Error %x", rc);
			goto err1;
        }
		
		CFRunLoopSourceRef rl_source;
		if((rc = (*interface)->createAsyncEventSource(interface, &rl_source)) != kIOReturnSuccess)
		{
			USBMX_LOG("(*interface)->createAsyncEventSource() Error %x", rc);
			goto err1;
		}

		CFRunLoopAddSource(
			CFRunLoopGetCurrent(),
			rl_source,
			kCFRunLoopDefaultMode);
		if((rc = ((IOHIDDeviceInterface122*)*interface)->setInterruptReportHandlerCallback(
			interface,
			dr->response_buffer,
			USBMX_RESPONSE_BUFFER_SIZE,
			InterruptReportHandler,
			(void *)dr,
			NULL)) != kIOReturnSuccess)
		{
			USBMX_LOG("(*interface)->setInterruptReportHandlerCallback() Error %x", rc);
			goto err1;
		}
	}
	
	*dev_out = dr;
	////////////////
	//USBMX_LOG("NEED TO CALL DEVICE ADDED CALLBACK");
	if(ctx->deviceAdded)
	{
		(*ctx->deviceAdded)(dr, ctx->deviceAdded_cookie);
	}
	////////////////
	return 0;
err1:
	(*dr->interface)->Release(dr->interface);
err:
	IOObjectRelease(dev);
	free(dr);
	return -1;
}

int USBmX_ScanForDevices(USBmX_ContextRef ctx)
{
	IOReturn rc;	
	io_iterator_t iterator;
	io_object_t d;
	int n_devices = 0;
	
	CFRetain(ctx->matchingDict);
	
	// Narrow it down to devices matching vendor and product IDs
	if(rc = IOServiceGetMatchingServices(
		kIOMasterPortDefault,
		ctx->matchingDict,
		&iterator) != kIOReturnSuccess)
	{
			USBMX_LOG("IOServiceGetMatchingServices Error %x", rc);
			goto err;
	}

	// Iterate over each found device
	while(d = IOIteratorNext(iterator))
	{
		USBmX_DeviceRef dev;
		if(CreateDeviceRef(ctx, d, &dev) < 0) goto err1;
		n_devices++;
	}
	
	IOObjectRelease(iterator);

noerr:
	return n_devices;
err1:
	IOObjectRelease(iterator);
err:
	USBMX_LOG("USBmX_FindDevices Failed!");
	return -1;
}

USBmX_ContextRef USBmX_Create(void)
{
	USBmX_ContextRef ctx = NULL;
	if(ctx = USBMX_ALLOC(USBmX_Context))
	{
		ctx->deviceList = NULL;
		ctx->matchingDict = NULL;
		ctx->deviceAdded = NULL;
		ctx->deviceRemoved = NULL;
		ctx->deviceAdded_cookie = NULL;
		ctx->deviceRemoved_cookie = NULL;
	}
	return ctx;
}

int USBmX_Begin(USBmX_ContextRef ctx)
{
//	USBmX_ContextRef ctx = USBMX_ALLOC(USBmX_Context);
//	ctx->deviceList = NULL;
//	ctx->matchingDict = NULL;
	if(!ctx) return -1;

	// Grab root IOKit HID services
	UNLESS(ctx->matchingDict = IOServiceMatching(kIOHIDDeviceKey))
	{
		USBMX_LOG("IOServiceMatching(kIOHIDDeviceKey) Error");
		goto err;
	}

	{	// Add product and vendor keys to matchingDict
		SInt32 product = USBMX_ID_PRODUCT;
		SInt32 vendor = USBMX_ID_VENDOR;
		CFNumberRef num = NULL;
		#define USBMX_DNA(NAME, VALUE) \
			UNLESS(num = CFNumberCreate( \
					kCFAllocatorDefault, \
					kCFNumberSInt32Type, \
					& VALUE )) { \
				USBMX_LOG("CFNumber Error"); \
				goto err; \
			} \
			CFDictionaryAddValue(ctx->matchingDict, CFSTR(NAME), num); \
			CFRelease(num);
		USBMX_DNA(kIOHIDVendorIDKey, vendor)
		USBMX_DNA(kIOHIDProductIDKey, product)
		#undef USBMX_DNA
	}

	{	// Set up onPlug handler
		io_iterator_t plugIterator;
		IONotificationPortRef plugPort;
		//CFRunLoopSourceRef runLoopSource;
		
		//CFMutableDictionaryRef hd = IOServiceMatching(kIOHIDDeviceKey);
		CFRetain(ctx->matchingDict);

		UNLESS(plugPort = IONotificationPortCreate(kIOMasterPortDefault))
		{
			USBMX_LOG("IONotificationPortCreate error");		
		}
		
		CFRunLoopAddSource(
			CFRunLoopGetCurrent(),
			IONotificationPortGetRunLoopSource(plugPort),
			kCFRunLoopDefaultMode);
		if(IOServiceAddMatchingNotification(
			plugPort,
			kIOFirstMatchNotification,
			ctx->matchingDict,
			DeviceAddedHandler,
			(void *)ctx,
			&plugIterator) != KERN_SUCCESS)
		{
			USBMX_LOG("IOServiceAddMatchingNotification error");		
		}
		DeviceAddedHandler((void *)ctx, plugIterator);
	}

	//if(USBmX_ScanForDevices(ctx) < 0) goto err;
noerr:
	//return ctx;
	return 0;
err:
	USBMX_LOG("USBmX_Init Failed!");
	free(ctx);
	//return NULL;
	return -1;
}

int USBmX_Destroy(USBmX_ContextRef ctx)
{
	if(!ctx) return -1;
	free(ctx);
	return 0;
}

int USBmX_InitPorts(USBmX_DeviceRef dev)
{
	int r;
	u_char res[8];
	static const u_char cmd[8] = {
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;
}

int USBmX_WriteA(USBmX_DeviceRef dev, u_char value)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x01,
		value,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;	
}

int USBmX_WriteB(USBmX_DeviceRef dev, u_char value)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x02,
		value,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;	
}

int USBmX_WriteABit(USBmX_DeviceRef dev, u_char v_and, u_char v_or)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x03,
		v_and,
		v_or,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;	
}

int USBmX_WriteBBit(USBmX_DeviceRef dev, u_char v_and, u_char v_or)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x04,
		v_and,
		v_or,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;	
}

int USBmX_ReadA(USBmX_DeviceRef dev, u_char *value_out)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x05,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(value_out) *value_out = res[1];
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;
}

int USBmX_ReadB(USBmX_DeviceRef dev, u_char *value_out)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x06,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(value_out) *value_out = res[1];
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;
}

int USBmX_SetBit(USBmX_DeviceRef dev, u_char line)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x07,
		line,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;
}

int USBmX_ResetBit(USBmX_DeviceRef dev, u_char line)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x08,
		line,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;
}

int USBmX_DirectionA(USBmX_DeviceRef dev, u_char dir0, u_char dir1)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x09,
		dir0,
		dir1,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;
}

int USBmX_DirectionB(USBmX_DeviceRef dev, u_char dir0, u_char dir1)
{
	int r;
	u_char res[8];
	u_char cmd[8] = {
		0x0A,
		dir0,
		dir1,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00
	};
	r = USBmX_RawCommand(dev, cmd, res);
	if(r < 0) return r;
	if(res[0] != cmd[0]) return -1;
	return 0;
}

int USBmX_StrobeWrite(USBmX_DeviceRef dev, 
	u_char data, 
	u_char port_select, 
	u_char strobe_line,
	u_char pulse_length)
{
	return -1;
}

int USBmX_StrobeRead(USBmX_DeviceRef dev, 
	u_char *data_out, 
	u_char port_select, 
	u_char strobe_line,
	u_char pulse_length)
{
	return -1;
}

int USBmX_StrobeWrites(USBmX_DeviceRef dev, 
	u_char n_bytes, 
	u_char bytes[])
{
	return -1;
}

int USBmX_InitLCD(USBmX_DeviceRef dev,
	u_char rw_select,
	u_char rs_select,
	u_char port_select,
	u_char e_select)
{
	return -1;
}

int USBmX_LCDCmd(USBmX_DeviceRef dev, u_char cmd)
{
	return -1;
}

int USBmX_LCDData(USBmX_DeviceRef dev, u_char data)
{
	return -1;
}
