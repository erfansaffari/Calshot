#import "VoiceAudioBoundary.h"

// Never include exception reasons: device/framework diagnostics can contain private data.
static NSError *AudioException(NSException *exception) {
    return [NSError errorWithDomain:@"com.calshot.audio.exception" code:1
                          userInfo:@{NSLocalizedDescriptionKey: @"The audio device rejected an operation.",
                                     @"exceptionName": exception.name}];
}
@implementation VoiceAudioBoundary
+ (AVAudioInputNode *)inputForEngine:(AVAudioEngine *)engine {
    @try { return engine.inputNode; }
    @catch (NSException *exception) { return nil; }
}
+ (AVAudioFormat *)outputFormatForEngine:(AVAudioEngine *)engine {
    @try { return [engine.outputNode outputFormatForBus:0]; }
    @catch (NSException *exception) { return nil; }
}
+ (NSError *)enableVoiceProcessing:(AVAudioInputNode *)input {
    @try { NSError *error = nil; [input setVoiceProcessingEnabled:YES error:&error]; return error; }
    @catch (NSException *exception) { return AudioException(exception); }
}
+ (NSError *)connectPlayer:(AVAudioPlayerNode *)player engine:(AVAudioEngine *)engine format:(AVAudioFormat *)format {
    @try { [engine attachNode:player]; [engine connect:player to:engine.mainMixerNode format:format]; return nil; }
    @catch (NSException *exception) { return AudioException(exception); }
}
+ (NSError *)installTap:(AVAudioInputNode *)input format:(AVAudioFormat *)format callback:(AVAudioNodeTapBlock)callback {
    @try { [input installTapOnBus:0 bufferSize:2048 format:format block:callback]; return nil; }
    @catch (NSException *exception) { return AudioException(exception); }
}
+ (NSError *)startEngine:(AVAudioEngine *)engine {
    @try { NSError *error = nil; [engine prepare]; BOOL started = [engine startAndReturnError:&error];
        if (!started && !error) error = [NSError errorWithDomain:@"com.calshot.audio.start" code:1 userInfo:nil];
        return error; }
    @catch (NSException *exception) { return AudioException(exception); }
}
+ (NSError *)removeTap:(AVAudioInputNode *)input {
    @try { [input removeTapOnBus:0]; return nil; }
    @catch (NSException *exception) { return AudioException(exception); }
}
+ (NSError *)stopEngine:(AVAudioEngine *)engine {
    @try { [engine stop]; return nil; }
    @catch (NSException *exception) { return AudioException(exception); }
}
+ (NSError *)stopPlayer:(AVAudioPlayerNode *)player {
    @try { [player stop]; return nil; }
    @catch (NSException *exception) { return AudioException(exception); }
}
+ (NSError *)scheduleBuffer:(AVAudioPCMBuffer *)buffer player:(AVAudioPlayerNode *)player completion:(AVAudioPlayerNodeCompletionHandler)completion {
    @try {
        [player scheduleBuffer:buffer completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack completionHandler:completion];
        if (!player.isPlaying) [player play];
        return nil;
    } @catch (NSException *exception) { return AudioException(exception); }
}
@end
