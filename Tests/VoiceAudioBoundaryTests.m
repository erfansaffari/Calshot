#import <XCTest/XCTest.h>
#import "../Sources/Voice/VoiceAudioBoundary.h"

// No microphone or real device graph: raise at the same AVFoundation entry points.
@interface RejectingVoiceEngine : AVAudioEngine
@property BOOL rejectPrepare;
@end
@implementation RejectingVoiceEngine
- (void)prepare { if (self.rejectPrepare) [NSException raise:NSInvalidArgumentException format:@"fictional device failure"]; }
- (BOOL)startAndReturnError:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"fictional.audio" code:42 userInfo:nil];
    return NO;
}
- (void)stop { [NSException raise:NSInternalInconsistencyException format:@"fictional teardown failure"]; }
@end
@interface RejectingVoicePlayer : AVAudioPlayerNode
@end
@implementation RejectingVoicePlayer
- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)type completionHandler:(AVAudioPlayerNodeCompletionHandler)completion {
    [NSException raise:NSInvalidArgumentException format:@"fictional playback failure"];
}
- (void)stop { [NSException raise:NSInternalInconsistencyException format:@"fictional stop failure"]; }
@end
@interface VoiceAudioBoundaryTests : XCTestCase
@end
@implementation VoiceAudioBoundaryTests
- (void)testStartupExceptionBecomesErrorBeforeReturningToSwift {
    RejectingVoiceEngine *engine = [RejectingVoiceEngine new];
    engine.rejectPrepare = YES;
    NSError *error = [VoiceAudioBoundary startEngine:engine];
    XCTAssertEqualObjects(error.domain, @"com.calshot.audio.exception");
    XCTAssertEqualObjects(error.userInfo[@"exceptionName"], NSInvalidArgumentException);
    XCTAssertFalse([error.description containsString:@"fictional device failure"]);
    engine.rejectPrepare = NO;
    // A fresh attempt still returns ordinary NSError failures unchanged.
    XCTAssertEqual([VoiceAudioBoundary startEngine:engine].code, 42);
}
- (void)testPlaybackAndStopExceptionsAreContained {
    RejectingVoicePlayer *player = [RejectingVoicePlayer new];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:24000 channels:1];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:32];
    buffer.frameLength = 32;
    __block BOOL completed = NO;
    XCTAssertNotNil([VoiceAudioBoundary scheduleBuffer:buffer player:player completion:^(AVAudioPlayerNodeCompletionCallbackType type) { completed = YES; }]);
    XCTAssertFalse(completed);
    XCTAssertNotNil([VoiceAudioBoundary stopPlayer:player]);
}
- (void)testTeardownExceptionIsContained {
    XCTAssertNotNil([VoiceAudioBoundary stopEngine:[RejectingVoiceEngine new]]);
}
@end
