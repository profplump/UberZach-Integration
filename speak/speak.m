#import <AppKit/AppKit.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/socket.h>

// The speach synth is global
NSSpeechSynthesizer *synth = NULL;

@interface SpeechDelegate : NSObject <NSSpeechSynthesizerDelegate>
@end

@implementation SpeechDelegate
- (void)speechSynthesizer: (NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)success {
	if (!success) {
		NSLog(@"Unable to speak");
	}
}
@end

@interface Socket : NSObject <NSStreamDelegate>
- (BOOL)listen:(NSString *)path;
static void sockCallback (CFSocketRef sock, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);

@property NSString *path;
@property CFSocketRef unixSocket;
@end

@implementation Socket

- (BOOL)listen:(NSString *)path {
	self.path = path;
	
	unlink([self.path cStringUsingEncoding:NSUTF8StringEncoding]);
	CFSocketContext CTX = { 0, (__bridge void *)(self), NULL, NULL, NULL };

	self.unixSocket = CFSocketCreate(NULL, PF_UNIX, SOCK_DGRAM, 0,
		kCFSocketDataCallBack, (CFSocketCallBack)sockCallback, &CTX);
	if (self.unixSocket == NULL) {
		return NO;
	} 

	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, [self.path cStringUsingEncoding:NSUTF8StringEncoding], sizeof(addr.sun_path) - 1);
	addr.sun_len = SUN_LEN(&addr);

	NSData *address = [ NSData dataWithBytes: &addr length: sizeof(addr) ];
	if (CFSocketSetAddress(self.unixSocket, (__bridge CFDataRef) address) != kCFSocketSuccess) {
		CFRelease(self.unixSocket);
		return NO;
	}

	CFRunLoopSourceRef sourceRef = CFSocketCreateRunLoopSource(kCFAllocatorDefault, self.unixSocket, 0);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), sourceRef, kCFRunLoopCommonModes);
	CFRelease(sourceRef);  
	return YES;
}

static void sockCallback (CFSocketRef sock, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
	switch(type) {
		case kCFSocketDataCallBack: {
			// Wait for other apps to stop speaking before we start
			// This provides no cordination with other waiting speakers
			while( [NSSpeechSynthesizer isAnyApplicationSpeaking] ) {
				[NSThread sleepForTimeInterval: 0.25];
			}

			// Speak
			NSString *str = [[NSString alloc] initWithData:(__bridge NSData*)data encoding:NSUTF8StringEncoding];
			[synth startSpeakingString: str];
			break;			
		}
		case kCFSocketNoCallBack:
		case kCFSocketAcceptCallBack:
		case kCFSocketConnectCallBack:
		case kCFSocketWriteCallBack:
		case kCFSocketReadCallBack: {
			break;
		}
	}
}

@end

int main(int argc, const char *argv[]) {

	// Construct a default socket path or use the provided one
	NSString *str;
	if (argc > 1) {
		str = [NSString stringWithUTF8String: argv[1]];
	}
	if ([str length] < 1) {
		NSString *tmpDir = NSTemporaryDirectory();
		str = [NSString stringWithFormat:@"%@plexMonitor/SPEAK.socket", tmpDir];
	}
	
	// Init the speech engine
	synth = [[NSSpeechSynthesizer alloc] init];
	[synth setDelegate: [SpeechDelegate new]];

	// Allow changes to the overall speech volume
	if (argc > 2) {
		NSString *val = [NSString stringWithUTF8String: argv[2]];
		NSNumberFormatter * f = [[NSNumberFormatter alloc] init];
		[f setNumberStyle:NSNumberFormatterDecimalStyle];

		NSNumber *volume = [f numberFromString: val];
		if ([volume floatValue] == 0.25 || [volume floatValue] == 0.5 || \
			[volume floatValue] == 0.75 || [volume floatValue] == 1.0) {
				[synth setObject: volume forProperty: NSSpeechVolumeProperty error: nil];
		} else {
			NSLog(@"Invalid volume: %f", [volume floatValue]);
		}
	}
	
	// Open the socket
	Socket *sock = [[Socket alloc] init];
	if (![sock listen:str]) {
		NSLog(@"Unable to open socket");
		exit(-1);
	}	

	// Run
	[[NSRunLoop currentRunLoop] run];

	// Cleanup (not reached)
	return 0;
}
