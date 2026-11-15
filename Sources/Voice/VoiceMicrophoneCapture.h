#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
/// All session/device/converter calls execute on one serial worker, inside Objective-C exception boundaries.
/// This capture path never creates an AVAudioEngine, output node, player or voice-processing AudioUnit.
@interface VoiceMicrophoneCapture : NSObject
- (void)startWithUID:(NSString *)uid
            samples:(void (^)(NSData *pcm16, float level))samples
            failure:(void (^)(NSError *error))failure
         completion:(void (^)(NSError * _Nullable error))completion;
/// Cancels immediately, including a queued start; worker cleanup releases the microphone.
- (void)stop;
@end

/// CPU-only conversion shared by the capture delegate and regression tests. Use on one serial queue.
@interface VoiceCaptureConverter : NSObject
- (nullable NSData *)convertBuffer:(AVAudioPCMBuffer *)input level:(float *)level error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
