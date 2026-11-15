# Independent microphone capture (1.0.9)

The owner reports that 1.0.8 crashes when Test microphone is pressed on the A18 Pro MacBook Neo, while its microphone works in other apps. This isolates the reproducer from the agent connection, screen capture and the notch: the Settings test uses none of them. No new crash report accompanies this observation, so the original throwing operation on that hardware is not established.

The old implementation still created a full AVAudioEngine graph for a microphone test: input/output nodes, player/mixer, optional voice processing and output format validation. Disabling voice processing did not separate microphone acquisition from that device graph. The independently reproduced notch-layout defect fixed in 1.0.8 was real, but did not eliminate this microphone-specific failure.

## Replacement

- Both the test and voice use AVCaptureSession + AVCaptureDeviceInput + AVCaptureAudioDataOutput, with the selected stable audio-device UID (or the system's default at startup). The capture path never creates an audio engine input node, speaker, mixer, or voice-processing AudioUnit. It never changes the system default.
- Configure, start, stop, native sample-buffer copying and conversion execute on one serial Objective-C worker, with typed exception boundaries. Input buffers retain their native device format; software conversion produces 24 kHz mono little-endian PCM16. A sample-rate change replaces only the converter.
- Swift startup is asynchronous. Native stop sets an atomic cancellation flag before worker cleanup, and Swift generations reject late completion, samples and errors. Bounded recovery creates a fresh capture session. Default-input changes and disconnection are fenced; a missing explicit selection stays an error.
- Speaker playback is created lazily for actual returned audio. An unavailable speaker cannot make Test microphone fail. Output reconfiguration discards its graph without reopening input. Session-updated/reconnect callbacks do not start input a second time.
- Remove the experimental echo-cancellation switch and its bridge field. Old preferences remain harmless; they cannot re-enable the removed backend. Existing push-to-talk playback interruption and suppression of self-audio remain.
- The test remains local-only. No audio file, model call, history item, screen capture, calendar write or memory learning occurs.

## Verification

- Full native suite on macOS 26.5.2: **484 passed, 0 skipped, 0 failed**, including the opt-in physical microphone test. That test received actual PCM audio for 800 ms on the local Mac using existing microphone permission, with no audio saved or sent (`build/MicrophoneCaptureVerification/VerifiedAudioTests.xcresult`).
- Unit tests prove that input startup and meter delivery cannot initialize the output factory, output failure is deferred until reply playback, denied permission creates neither backend, Stop fences an asynchronous start and late samples, reconnect does not reopen input, native format exceptions become errors, and a stopped native capture cannot start a queued device request.
- CPU-only native conversion tests cover 44.1/48/96 kHz stereo input, mono PCM16 output and sound on a non-first input channel.
- WebUI: 247 tests passed; production build passed. The picker, local test and persistent errors remain; the unsupported processing control is gone.
- The affected Neo is not the local test machine. Its exact failing instruction remains unknown without a fresh report. The physical local test and source-level separation verify the replacement path, not a claim that every audio driver fault is prevented.

Additional verification before release: a hardware run with an explicit selected UID also passed and confirmed that picker UIDs identify AVCapture audio devices (`build/MicrophoneCaptureVerification/SelectedInputHardware.xcresult`). The final independent-input tests passed after adding empty/malformed reply checks: neither may initialize speaker hardware. Browser inspection at 920 × 650 and 1440 × 900 confirmed the picker/test/meter remain and the processing switch is absent, with no horizontal page overflow. Fresh native-window inspection was unavailable because Computer Use returned `cgWindowNotFound`; the physical capture test above exercised the production backend directly.
