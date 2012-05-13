#ifndef _USBMICROX_H_
#define _USBMICROX_H_

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <libgen.h>
#include <mach/mach.h>
#include <sys/types.h>
#include <CoreFoundation/CFNumber.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hid/IOHIDKeys.h>

#define USBMX_LOG(S, ...) \
	({ fprintf(stderr, "/%s/%s/%d >>> " S "\n", basename(__FILE__) , \
	__FUNCTION__ , __LINE__ , ## __VA_ARGS__ ); })
#define USBMX_CMD(...) (u_char[8]){ __VA_ARGS__ }
#define USBMX_ALLOC(TYPE) (TYPE*)malloc(sizeof(TYPE))

#define USBMX_DEBUG_LOG 0
#define USBMX_RESPONSE_BUFFER_SIZE 8

struct _USBmX_Context;

typedef struct _USBmX_Device {
	struct _USBmX_Context *ctx;
	IOHIDDeviceInterface **interface;
	CFMutableDictionaryRef properties;
	const char *serialNumber;
	const char *deviceName;
	const char *manufacturer;
	int response_ready;
	u_char response_buffer[USBMX_RESPONSE_BUFFER_SIZE];
	struct _USBmX_Device *next;
	void *userData;
} USBmX_Device;
typedef USBmX_Device* USBmX_DeviceRef;

typedef void (*USBmX_DeviceAddedProc)(USBmX_DeviceRef dev, void *cookie);
typedef void (*USBmX_DeviceRemovedProc)(USBmX_DeviceRef dev, void *cookie);

typedef struct _USBmX_Context {
	USBmX_DeviceRef deviceList;
	CFMutableDictionaryRef matchingDict;
	USBmX_DeviceAddedProc deviceAdded;
	USBmX_DeviceRemovedProc deviceRemoved;
	void *deviceAdded_cookie;
	void *deviceRemoved_cookie;
} USBmX_Context;
typedef USBmX_Context* USBmX_ContextRef;

/*
 *	USBmX_Create:
 *	Creates a USBmX_ContextRef used in all other
 *	routines.  Should return a valid USBmX_ContextRef
 *	even if no devices are conected.
 */
extern USBmX_ContextRef USBmX_Create(void);

extern int USBmX_DeviceAddedHandler(
			USBmX_ContextRef ctx, 
			USBmX_DeviceAddedProc proc, 
			void *cookie);
extern int USBmX_DeviceRemovedHandler(
			USBmX_ContextRef ctx, 
			USBmX_DeviceRemovedProc proc, 
			void *cookie);

/*
 *	USBmX_Begin:
 *	You must call USBmX_Begin to init the USB
 *	subsystem.  Call before sending any commands.
 *	Returns < 0 on error.
 */
extern int USBmX_Begin(USBmX_ContextRef ctx);

/*
 *	USBmX_ScanForDevices:
 *	Call to manually re-scan the USB bus for newly
 *	connected devices.  You should never have to
 *	call this yourself (there are internal
 *	notifications that should call this automatically
 *	when a device is plugged in.
 *	Returns < 0 on error.
 */
extern int USBmX_ScanForDevices(USBmX_ContextRef ctx);

/*
 *	USBmX_Destroy:
 *	Call when you are done messing with all devices.
 */
extern int USBmX_Destroy(USBmX_ContextRef ctx);

/*
 *	USBmX_DeviceCount:
 *	Get the number of connected devices.
 */
extern int USBmX_DeviceCount(USBmX_ContextRef ctx);

/*
 *	USBmX_DefaultDevice:
 *	Get the default devico (generally the last device
 *	that was plugged in.  Useful if you only have 1
 *	device plugged in and don't want to mess with the
 *	serial number.  Returns NULL if there are no
 *	devices connected.
 */
extern USBmX_DeviceRef USBmX_DefaultDevice(USBmX_ContextRef ctx);

/*
 *	USBmX_DeviceWithSerial:
 *	Get the device matching the provided serial
 *	number.  Returns NULL if the device cannot be
 *	found.
 */
extern USBmX_DeviceRef USBmX_DeviceWithSerial(USBmX_ContextRef ctx, const char *serial);

/*
 *	USBmX_DumpCommand:
 *	Small utility function that prints out an 8 byte
 *	buffer in human readable form.  Useful for
 *	printing commands and responses.
 */
extern void USBmX_DumpCommand(u_char buf[]);

/*
 *	USBmX_DeviceInfo:
 *	Outputs as much infomation as possible on a
 *	given device.
 */
extern int USBmX_DeviceInfo(USBmX_DeviceRef dev);


/*
*****************************************************
*****************  Commands  ************************
*****************************************************
The following command functions return 0 on success
and < 0 on error.

Where the command demands that you chose a 'line'
(A0..A7, or B0..B7), the table below may be helpful:
Value	Line
-----	----
0x00	A0
0x01	A1
0x02	A2
0x03	A3
0x04	A4
0x05	A5
0x06	A6
0x07	A7
0x08	B0
0x09	B1
0x0A	B2
0x0B	B3
0x0C	B4
0x0D	B5
0x0E	B6
0x0F	B7
*/


/*
 *	USBmX_RawCommand:
 *	Performs a raw command on the specifie device.
 *	More info can be found here:
 *	http://usbmicro.com/odn/index.html
 *	under "Raw Command Summary"
 */
extern int USBmX_RawCommand(USBmX_DeviceRef dev, 
	const u_char command[8], 
	u_char response[8]);

/*
The initial state of the ports on power up is that all
of the 16 lines are set to be inputs. This command 
duplicates the power up conditions of setting all lines 
to input.
*/
extern int USBmX_InitPorts(USBmX_DeviceRef dev);

/*
Write a byte value to specified port. The possible values 
range from 0-255 (0x00..0xFF) (passed in value).
*/
extern int USBmX_WriteA(USBmX_DeviceRef dev, u_char value);
extern int USBmX_WriteB(USBmX_DeviceRef dev, u_char value);

/*
Write masked values to specified port. The net result of 
writing masked values is that only the specified bits will 
be written. The resulting port condition is the logic 
combination of the current port state ANDed with the 
first term (v_and) and then ORed with the second (v_or). 
This command can affect any number of lines on the port.
*/
extern int USBmX_WriteABit(USBmX_DeviceRef dev, u_char v_and, u_char v_or);
extern int USBmX_WriteBBit(USBmX_DeviceRef dev, u_char v_and, u_char v_or);

/*
Read a byte value from specified port. The returned value
(returned in *value_out) is the state of the port lines that 
an external device has set, if the line is an input. 
The lines that might be configured as outputs return the 
output state.
*/
extern int USBmX_ReadA(USBmX_DeviceRef dev, u_char *value_out);
extern int USBmX_ReadB(USBmX_DeviceRef dev, u_char *value_out);

/*
Set a single bit/line high. (0..15)
*/
extern int USBmX_SetBit(USBmX_DeviceRef dev, u_char line);

/*
Set a single bit/line low. (0..15)
*/
extern int USBmX_ResetBit(USBmX_DeviceRef dev, u_char line);

/*
Set the i/o direction of specified port.
dir0 is written to the direction0 control register, dir1 
is written to the direction1 control register appropriate 
for the port.
The individual pins of the ports can be set to input, or 
output. Input is set when both bits associated with a 
particular line are set to 0. There are different types 
of outputs available for the board, but generally setting 
both of the direction bits to 1 will suffice.
High order bits of dir0 and dir1 correspond to high order
lines.
*/
extern int USBmX_DirectionA(USBmX_DeviceRef dev, u_char dir0, u_char dir1);
extern int USBmX_DirectionB(USBmX_DeviceRef dev, u_char dir0, u_char dir1);

/*
Strobe write of a byte value to a port. This command 
selects port A (port_select=0x00) or B (port_select=0x01) 
for the written byte, as well as a polarity (negative or 
positive) and a line (A.0 - B.7 (strobe_line=0..15)) to 
toggle. The byte is written and then the line toggled.
pulse_length can be anywhere between 0x00..0xFF.
Default is to have the strobe negative-going 
(high->low->high).  Add 0x10 to strobe_line to have the
pulse be positive-going (low->high->low).
*/
extern int USBmX_StrobeWrite(USBmX_DeviceRef dev, 
	u_char data, 
	u_char port_select, 
	u_char strobe_line,
	u_char pulse_length);

/*
Strobe read of a byte value from a port. This command 
selects port A (port_select=0x00) or B (port_select=0x01) 
for the read byte, as well as a polarity (negative or 
positive) and a line (A.0 - B.7 (strobe_line=0..15)) to 
toggle. The line is toggled and the byte is read.
pulse_length can be anywhere between 0x00..0xFF.
Default is to have the strobe negative-going 
(high->low->high).  Add 0x10 to strobe_line to have the
pulse be positive-going (low->high->low).
*data_out is set to the byte read.
*/
extern int USBmX_StrobeRead(USBmX_DeviceRef dev, 
	u_char *data_out, 
	u_char port_select, 
	u_char strobe_line,
	u_char pulse_length);

/*
Strobe write of a 1 to 6 byte value to a port. This 
command uses port A or B for the written byte, as well 
as a polarity (negative or positive) and a line 
(A.0 - B.7) to toggle based on the previously executed 
USBmX_StrobeWrite or USBmX_StrobeRead.
Control this command's port for the written byte, 
polarity and strobe line by using the USBmX_StrobeWrite 
or USBmX_StrobeRead. This command will then use the 
same selected port, polarity, and strobe line to write 
up to 6 bytes.
n_bytes is the number of bytes to write.
bytes[] is an array of bytes, the first n_bytes values
will be written.  It must be at least of size n_bytes.
*/
extern int USBmX_StrobeWrites(USBmX_DeviceRef dev, 
	u_char n_bytes, 
	u_char bytes[]);

/*
Strobe read of a 1 to 6 byte value from a port. This 
command uses port A or B for the read byte, as well 
as a polarity (negative or positive) and a line 
(A.0 - B.7) to toggle based on the previously executed 
USBmX_StrobeWrite or USBmX_StrobeRead.
Control this command's port for the written byte, 
polarity and strobe line by using the USBmX_StrobeWrite 
or USBmX_StrobeRead. This command will then use the 
same selected port, polarity, and strobe line to read 
up to 6 bytes.
n_bytes is the number of bytes to read.
bytes[] is an array of bytes that the read values will be 
copied into.  It must be at least of size n_bytes.
*/
extern int USBmX_StrobeReads(USBmX_DeviceRef dev, 
	u_char n_bytes, 
	u_char bytes[]);

/*
Initialize LCD variables. This includes the selection 
of the lines used for RW, RS, E and the port used for 
data. RW, RS, and E are reset. These commands are 
appropriate for HD44780 devices and devices that are 
compatible.
port_select = 0 for port A, or 1 for port B.
See table (way) above for line->number mappings.
*/
extern int USBmX_InitLCD(USBmX_DeviceRef dev,
	u_char rw_select,
	u_char rs_select,
	u_char port_select,
	u_char e_select);
	
/*
Write a command to the LCD. The RS, RW, E lines and the 
data port are selected by the USBmX_InitLCD. The data 
byte is written to the selected port and the control 
lines are set appropriately. The E line is toggled for 
five to eight microseconds.
*/
extern int USBmX_LCDCmd(USBmX_DeviceRef dev, u_char cmd);

/*
Write a character to the LCD. The RS, RW, E lines and 
the data port are selected by the USBmX_InitLCD. The data 
byte is written to the selected port and the control 
lines are set appropriately. The E line is toggled for 
five to eight microseconds.
*/
extern int USBmX_LCDData(USBmX_DeviceRef dev, u_char data);

// TODO: SPI + Stepper

#endif /* _USBMICROX_H_ */
