#import "VoiceAudioBoundary.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioUnit/AudioUnit.h>

// Never include exception reasons: device/framework diagnostics can contain private data.
static NSError *AudioException(NSException *exception) {
    return [NSError errorWithDomain:@"com.calshot.audio.exception" code:1
                          userInfo:@{NSLocalizedDescriptionKey: @"The audio device rejected an operation.",
                                     @"exceptionName": exception.name}];
}
@implementation VoiceAudioBoundary
+ (NSArray<NSDictionary<NSString *, id> *> *)inputDevices {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, data.mutableBytes) != noErr) return @[];
    NSMutableArray *result = [NSMutableArray array];
    AudioDeviceID *devices = data.mutableBytes;
    for (NSUInteger index = 0; index < size / sizeof(AudioDeviceID); index++) {
        AudioDeviceID device = devices[index]; UInt32 streamsSize = 0;
        AudioObjectPropertyAddress streams = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &streamsSize) != noErr || streamsSize == 0) continue;
        CFStringRef uid = NULL, name = NULL;
        UInt32 textSize = sizeof(CFStringRef);
        AudioObjectPropertyAddress property = { kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        OSStatus status = AudioObjectGetPropertyData(device, &property, 0, NULL, &textSize, &uid);
        property.mSelector = kAudioObjectPropertyName; textSize = sizeof(CFStringRef);
        if (status == noErr && uid && AudioObjectGetPropertyData(device, &property, 0, NULL, &textSize, &name) == noErr && name) {
            [result addObject:@{ @"uid": (__bridge NSString *)uid, @"name": (__bridge NSString *)name, @"id": @(device) }];
        }
        if (uid) CFRelease(uid); if (name) CFRelease(name);
    }
    return result;
}
+ (NSError *)selectInputUID:(NSString *)uid engine:(AVAudioEngine *)engine {
    if (uid.length == 0) return nil; // Follow macOS without changing its global default.
    @try {
        NSNumber *identifier = nil;
        for (NSDictionary *device in self.inputDevices) if ([device[@"uid"] isEqual:uid]) { identifier = device[@"id"]; break; }
        if (!identifier) return [NSError errorWithDomain:@"com.calshot.audio.input" code:1 userInfo:nil];
        AudioUnit unit = engine.inputNode.audioUnit;
        if (!unit) return [NSError errorWithDomain:@"com.calshot.audio.input" code:2 userInfo:nil];
        AudioDeviceID device = identifier.unsignedIntValue;
        OSStatus status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device));
        if (status != noErr) return [NSError errorWithDomain:@"com.calshot.audio.input" code:status userInfo:nil];
        AudioDeviceID actual = kAudioObjectUnknown; UInt32 size = sizeof(actual);
        status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size);
        if (status != noErr || actual != device) return [NSError errorWithDomain:@"com.calshot.audio.input" code:3 userInfo:nil];
        return nil;
    } @catch (NSException *exception) { return AudioException(exception); }
}
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
