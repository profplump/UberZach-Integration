#import <Cocoa/Cocoa.h>

@interface MDAppController : NSObject <NSApplicationDelegate>
@property (retain) NSString *outfile;
@end

@implementation MDAppController 
- (id)init {
    if ((self = [super init])) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                      selector:@selector(activeAppDidChange:)
               name:NSWorkspaceDidActivateApplicationNotification object:nil];
    }
    return self;
}
- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [super dealloc];
}
- (void)activeAppDidChange:(NSNotification *)notification {
    NSRunningApplication* runningApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
	NSString *str = [NSString stringWithFormat:@"%@\n", runningApp.bundleIdentifier];
	if (![str writeToFile:[self outfile] atomically:YES encoding:NSStringEncodingConversionAllowLossy error:nil]) {
		NSLog(@"Unable to write to path: %@", [self outfile]);
	}
}
@end

int main(int argc, const char * argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];

    MDAppController *appController = [[MDAppController alloc] init];
    [NSApp setDelegate:appController];

	// Construct a default path or use the provided one
	if (argc > 1) {
		NSString *str = [NSString stringWithUTF8String: argv[1]];
		[appController setOutfile:str];
	} else {
		NSString *tmpDir = NSTemporaryDirectory();
		[appController setOutfile:[NSString stringWithFormat:@"%@plexMonitor/FRONT_APP", tmpDir]];
	}

	// Force an update at init
	[appController activeAppDidChange:nil];

	// Wait forever
    [NSApp run];

	// Never reached
    [pool release];
	return 0;
}
