#import <AppKit/AppKit.h>

@interface SpeechDelegate : NSObject <NSSpeechSynthesizerDelegate>
@end

@implementation SpeechDelegate
- (void)speechSynthesizer: (NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)success {
	if (!success) {
		exit(-3);
	}
	exit(0);
}
@end

int main(int argc, const char *argv[]) {
	if (argc < 2) {
		return -1;
	}

	// Init the speech engine
	NSSpeechSynthesizer *synth = [[NSSpeechSynthesizer alloc] init];
	[synth setDelegate: [SpeechDelegate new]];

	// Convert from c-string to NSString
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *str = [NSString stringWithUTF8String: argv[1]];

	// Wait for other apps to stop speaking before we start
	// This provides no cordination with other waiting speakers
	while( [NSSpeechSynthesizer isAnyApplicationSpeaking] ) {
		[NSThread sleepForTimeInterval: 0.25];
	}

	// Speak
	[synth startSpeakingString: str];
	[[NSRunLoop currentRunLoop] run];

	// Cleanup (not reached)
	[pool drain];
	return 0;
}
