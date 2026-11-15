#import "VoiceMicrophoneCapture.h"
#import <stdatomic.h>
#import <CoreAudio/CoreAudio.h>
#import <math.h>

static NSError *CaptureError(NSInteger code) {
    return [NSError errorWithDomain:@"com.calshot.microphone" code:code
                          userInfo:@{NSLocalizedDescriptionKey: @"The microphone could not deliver audio. Choose an input in Settings → Voice and test again."}];
}

@implementation VoiceCaptureConverter {
    AVAudioConverter *_converter;
    AVAudioFormat *_source;
    AVAudioFormat *_mono;
}
- (NSData *)convertBuffer:(AVAudioPCMBuffer *)input level:(float *)level error:(NSError **)error {
    @try {
        if (level) *level = 0;
        AVAudioFormat *source = input.format;
        double capacity = ceil(input.frameLength * 24000.0 / source.sampleRate) + 64;
        if (!isfinite(source.sampleRate) || source.sampleRate <= 0 || source.channelCount == 0 || source.channelCount > 64 ||
            !isfinite(capacity) || capacity < 1 || capacity > 2000000) {
            if (error) *error = CaptureError(4); return nil;
        }
        if (!_converter || ![_source isEqual:source]) {
            _source = source;
            _mono = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:24000 channels:1];
            _converter = [[AVAudioConverter alloc] initFromFormat:source toFormat:_mono];
            if (!_converter) { if (error) *error = CaptureError(4); return nil; }
            _converter.downmix = YES;
        }
        AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_mono frameCapacity:(AVAudioFrameCount)capacity];
        if (!output) { if (error) *error = CaptureError(4); return nil; }
        __block BOOL supplied = NO;
        NSError *conversionError = nil;
        AVAudioConverterOutputStatus status = [_converter convertToBuffer:output error:&conversionError withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *state) {
            if (supplied) { *state = AVAudioConverterInputStatus_NoDataNow; return nil; }
            supplied = YES; *state = AVAudioConverterInputStatus_HaveData; return input;
        }];
        if (status == AVAudioConverterOutputStatus_Error || conversionError || !output.floatChannelData) {
            if (error) *error = CaptureError(4); return nil;
        }
        NSMutableData *data = [NSMutableData dataWithLength:output.frameLength * 2];
        uint8_t *bytes = data.mutableBytes; const float *values = output.floatChannelData[0]; double energy = 0;
        for (AVAudioFrameCount i = 0; i < output.frameLength; i++) {
            float value = isnan(values[i]) ? 0 : fminf(1, fmaxf(-1, values[i]));
            energy += value * value;
            int16_t sample = (int16_t)(value < 0 ? value * 32768 : value * 32767);
            uint16_t bits = (uint16_t)sample; bytes[i * 2] = bits & 255; bytes[i * 2 + 1] = bits >> 8;
        }
        if (level && output.frameLength) *level = fmin(1, sqrt(energy / output.frameLength));
        return data;
    } @catch (NSException *exception) { if (error) *error = CaptureError(4); return nil; }
}
@end

@interface VoiceMicrophoneCapture () <AVCaptureAudioDataOutputSampleBufferDelegate>
@end
@implementation VoiceMicrophoneCapture {
    dispatch_queue_t _queue;
    atomic_bool _stopped;
    AVCaptureSession *_session;
    AVCaptureAudioDataOutput *_output;
    VoiceCaptureConverter *_converter;
    id _runtimeObserver;
    id _interruptionObserver;
    id _disconnectObserver;
    AudioObjectPropertyListenerBlock _defaultListener;
    void (^_samples)(NSData *, float);
    void (^_failure)(NSError *);
}
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.calshot.microphone.capture", DISPATCH_QUEUE_SERIAL);
        atomic_init(&_stopped, false);
    }
    return self;
}
- (void)startWithUID:(NSString *)uid samples:(void (^)(NSData *, float))samples failure:(void (^)(NSError *))failure completion:(void (^)(NSError *))completion {
    dispatch_async(_queue, ^{
        if (atomic_load(&self->_stopped)) { completion(CaptureError(5)); return; }
        self->_samples = [samples copy]; self->_failure = [failure copy];
        @try {
            AVCaptureDevice *device = uid.length ? [AVCaptureDevice deviceWithUniqueID:uid] : [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            if (!device || ![device hasMediaType:AVMediaTypeAudio]) { [self cleanUp]; completion(CaptureError(uid.length ? 2 : 1)); return; }
            if (atomic_load(&self->_stopped)) { [self cleanUp]; completion(CaptureError(5)); return; }
            NSError *error = nil;
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
            if (!input || error) { [self cleanUp]; completion(CaptureError(3)); return; }
            self->_session = [AVCaptureSession new];
            self->_output = [AVCaptureAudioDataOutput new];
            // Preserve the device's native PCM format; conversion happens after capture, never in hardware setup.
            [self->_output setSampleBufferDelegate:self queue:self->_queue];
            if (![self->_session canAddInput:input]) {
                [self cleanUp]; completion(CaptureError(3)); return;
            }
            [self->_session addInput:input];
            if (![self->_session canAddOutput:self->_output]) { [self cleanUp]; completion(CaptureError(3)); return; }
            [self->_session addOutput:self->_output];
            self->_converter = [VoiceCaptureConverter new];
            __weak VoiceMicrophoneCapture *weakSelf = self;
            self->_runtimeObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self->_session queue:nil usingBlock:^(NSNotification *note) {
                VoiceMicrophoneCapture *owner = weakSelf;
                if (owner) dispatch_async(owner->_queue, ^{ [owner fail:CaptureError(3)]; });
            }];
            self->_interruptionObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionWasInterruptedNotification object:self->_session queue:nil usingBlock:^(NSNotification *note) {
                VoiceMicrophoneCapture *owner = weakSelf;
                if (owner) dispatch_async(owner->_queue, ^{ [owner fail:CaptureError(3)]; });
            }];
            self->_disconnectObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureDeviceWasDisconnectedNotification object:device queue:nil usingBlock:^(NSNotification *note) {
                VoiceMicrophoneCapture *owner = weakSelf;
                if (owner) dispatch_async(owner->_queue, ^{ [owner fail:CaptureError(3)]; });
            }];
            if (uid.length == 0) {
                self->_defaultListener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
                    VoiceMicrophoneCapture *owner = weakSelf;
                    // Defer cleanup until the Core Audio callback has returned, including listener removal.
                    if (owner) dispatch_async(owner->_queue, ^{ [owner fail:CaptureError(3)]; });
                };
                AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, self->_queue, self->_defaultListener);
            }
            if (atomic_load(&self->_stopped)) { [self cleanUp]; completion(CaptureError(5)); return; }
            [self->_session startRunning];
            if (atomic_load(&self->_stopped)) { [self cleanUp]; completion(CaptureError(5)); return; }
            if (!self->_session.isRunning) { [self cleanUp]; completion(CaptureError(3)); return; }
            completion(nil);
        } @catch (NSException *exception) { [self cleanUp]; completion(CaptureError(3)); }
    });
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (atomic_load(&_stopped)) return;
    @try {
        CMItemCount frames = CMSampleBufferGetNumSamples(sampleBuffer);
        CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (frames <= 0) return;
        if (!description || frames > 262144) { [self fail:CaptureError(4)]; return; }
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithCMAudioFormatDescription:description];
        if (!format || format.streamDescription->mFormatID != kAudioFormatLinearPCM) { [self fail:CaptureError(4)]; return; }
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)frames];
        if (!input) { [self fail:CaptureError(4)]; return; }
        input.frameLength = (AVAudioFrameCount)frames;
        if (CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, 0, (int32_t)frames, input.mutableAudioBufferList) != noErr) { [self fail:CaptureError(4)]; return; }
        NSError *error = nil; float level = 0;
        NSData *data = [_converter convertBuffer:input level:&level error:&error];
        if (!data || error) { [self fail:error ?: CaptureError(4)]; return; }
        if (!atomic_load(&_stopped) && data.length && _samples) _samples(data, level);
    } @catch (NSException *exception) { [self fail:CaptureError(4)]; }
}
- (void)fail:(NSError *)error {
    if (atomic_exchange(&_stopped, true)) return;
    void (^callback)(NSError *) = _failure;
    [self cleanUp];
    if (callback) callback(error);
}
- (void)cleanUp {
    if (_runtimeObserver) [NSNotificationCenter.defaultCenter removeObserver:_runtimeObserver]; _runtimeObserver = nil;
    if (_interruptionObserver) [NSNotificationCenter.defaultCenter removeObserver:_interruptionObserver]; _interruptionObserver = nil;
    if (_disconnectObserver) [NSNotificationCenter.defaultCenter removeObserver:_disconnectObserver]; _disconnectObserver = nil;
    if (_defaultListener) {
        AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, _queue, _defaultListener);
        _defaultListener = nil;
    }
    // Cleanup operations are independent: one rejecting device must not prevent the rest from releasing.
    @try { [_output setSampleBufferDelegate:nil queue:NULL]; } @catch (NSException *exception) { }
    @try { [_session stopRunning]; } @catch (NSException *exception) { }
    _output = nil; _session = nil; _converter = nil; _samples = nil; _failure = nil;
}
- (void)stop {
    atomic_store(&_stopped, true);
    dispatch_async(_queue, ^{ [self cleanUp]; });
}
@end
