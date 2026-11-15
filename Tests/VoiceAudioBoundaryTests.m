#import <XCTest/XCTest.h>
#import "../Sources/Voice/VoiceAudioBoundary.h"
#import "../Sources/Voice/VoiceMicrophoneCapture.h"

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
@interface RejectingPCMSource : NSObject
@end
@implementation RejectingPCMSource
- (AVAudioFormat *)format { [NSException raise:NSInvalidArgumentException format:@"fictional format failure"]; return nil; }
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
- (void)testCaptureConvertsNativeSampleRatesAndStereoInputToMonoPCM16 {
    for (NSNumber *rate in @[@44100, @48000, @96000]) {
        VoiceCaptureConverter *converter = [VoiceCaptureConverter new];
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate.doubleValue channels:2];
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4800];
        input.frameLength = 4800;
        for (NSUInteger i = 0; i < input.frameLength; i++) { input.floatChannelData[0][i] = 0; input.floatChannelData[1][i] = 0.5; }
        NSError *error = nil; float level = 0;
        NSData *data = [converter convertBuffer:input level:&level error:&error];
        XCTAssertNil(error); XCTAssertNotNil(data); XCTAssertGreaterThan(data.length, 0U); XCTAssertEqual(data.length % 2, 0U);
        XCTAssertGreaterThan(level, 0.01f); XCTAssertLessThanOrEqual(level, 1.0f);
        XCTAssertLessThanOrEqual(data.length, (NSUInteger)(ceil(input.frameLength * 24000.0 / rate.doubleValue) + 64) * 2);
    }
}
- (void)testCaptureConverterContainsNativeFormatExceptions {
    VoiceCaptureConverter *converter = [VoiceCaptureConverter new];
    NSError *error = nil; float level = 0;
    XCTAssertNil([converter convertBuffer:(AVAudioPCMBuffer *)[RejectingPCMSource new] level:&level error:&error]);
    XCTAssertEqual(error.code, 4);
}
- (void)testStoppedCaptureCannotPerformAQueuedDeviceStart {
    VoiceMicrophoneCapture *capture = [VoiceMicrophoneCapture new];
    [capture stop];
    XCTestExpectation *done = [self expectationWithDescription:@"cancelled capture"];
    [capture startWithUID:@"fictional-device-that-does-not-exist" samples:^(NSData *data, float level) { XCTFail(@"Stopped capture delivered samples"); }
                  failure:^(NSError *error) { XCTFail(@"Cancelled start must use its completion"); }
               completion:^(NSError *error) { XCTAssertEqual(error.code, 5); [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:5];
}
- (void)testTeardownExceptionIsContained {
    XCTAssertNotNil([VoiceAudioBoundary stopEngine:[RejectingVoiceEngine new]]);
}
@end
