#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Catch inside Objective-C, before an exception can unwind any Swift/async frame.
/// Do not replace these typed operations with a block supplied by Swift.
@interface VoiceAudioBoundary : NSObject
+ (nullable AVAudioInputNode *)inputForEngine:(AVAudioEngine *)engine;
+ (nullable AVAudioFormat *)outputFormatForEngine:(AVAudioEngine *)engine;
+ (nullable NSError *)enableVoiceProcessing:(AVAudioInputNode *)input;
+ (nullable NSError *)connectPlayer:(AVAudioPlayerNode *)player engine:(AVAudioEngine *)engine format:(AVAudioFormat *)format;
+ (nullable NSError *)installTap:(AVAudioInputNode *)input format:(AVAudioFormat *)format callback:(AVAudioNodeTapBlock)callback;
+ (nullable NSError *)startEngine:(AVAudioEngine *)engine;
+ (nullable NSError *)removeTap:(AVAudioInputNode *)input;
+ (nullable NSError *)stopEngine:(AVAudioEngine *)engine;
+ (nullable NSError *)stopPlayer:(AVAudioPlayerNode *)player;
+ (nullable NSError *)scheduleBuffer:(AVAudioPCMBuffer *)buffer player:(AVAudioPlayerNode *)player completion:(AVAudioPlayerNodeCompletionHandler)completion;
@end
NS_ASSUME_NONNULL_END
