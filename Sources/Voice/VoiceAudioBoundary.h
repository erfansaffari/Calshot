#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Catch inside Objective-C, before an exception can unwind any Swift/async frame.
/// Do not replace these typed operations with a block supplied by Swift.
@interface VoiceAudioBoundary : NSObject
+ (NSArray<NSDictionary<NSString *, id> *> *)inputDevices;
+ (nullable AVAudioFormat *)outputFormatForEngine:(AVAudioEngine *)engine;
+ (nullable NSError *)connectPlayer:(AVAudioPlayerNode *)player engine:(AVAudioEngine *)engine format:(AVAudioFormat *)format;
+ (nullable NSError *)startEngine:(AVAudioEngine *)engine;
+ (nullable NSError *)stopEngine:(AVAudioEngine *)engine;
+ (nullable NSError *)stopPlayer:(AVAudioPlayerNode *)player;
+ (nullable NSError *)scheduleBuffer:(AVAudioPCMBuffer *)buffer player:(AVAudioPlayerNode *)player completion:(AVAudioPlayerNodeCompletionHandler)completion;
@end
NS_ASSUME_NONNULL_END
