# Voice crash follow-up and microphone settings

The second report is from Calshot 1.0.7 (1011), macOS 26.6, Apple Silicon. It again contains the swallowed Objective-C exception marker and faults in a Swift main-executor check, this time during a SwiftUI button gesture routed through NotchPanel.sendEvent. The report alone still lacks the original exception stack. The 1.0.7 audio boundary did not fix the reported crash.

## Reproduced source defect

On macOS 26.5.2, run the old Debug app under LLDB with `--voice-preview` and a symbolic breakpoint on `_NSDetectedLayoutRecursion`. The isolated fixture uses fake audio, model and calendar services. It stops in `NotchExperienceController.position`'s animation completion at `panel.setFrame(frame, display: true)`. The stack below that call contains `NSHostingView.layout`, `ViewGraphRootValueUpdater.render` and `Update.dispatchActions`: a window resize is reentering its own active SwiftUI layout. This establishes a source defect independently of microphone hardware; it does not prove that every exception on the other Mac originates there.

Evidence: `build/voice-layout-debug.log`. The corresponding fixture in the patched build ran through listening/thinking/speaking/review/error transitions without hitting the layout-recursion or Objective-C exception breakpoints (`build/voice-layout-patched-debug.log`), then was stopped deliberately. The regression test also verifies that opening the notch cannot synchronously change its window geometry on the caller's stack.

## Changes

- Defer/coalesce notch window geometry, order and focus changes. Defer animation completion frame commits and retain transition-generation checks. Avoid synchronous forced display. Remove focus changes from the panel's event dispatch override; opening controls still explicitly requests key status after the callback unwinds, and WebKit keeps first inactive clicks.
- Use ordinary audio graphs by default for push-to-talk. Echo cancellation becomes an explicit device-local option; opting in retains the fresh-graph fallback. The previous native exception boundary remains in place.
- Enumerate input-capable Core Audio devices and save a stable UID, not an ephemeral device ID. Apply/verify the selected input on the voice engine's own AudioUnit, never on the system default. Resolve selection before validating hardware formats. Missing selected inputs fail visibly without fallback to another microphone.
- Add Settings → Voice input selection, refresh, optional echo cancellation and a 15-second microphone test. Test audio is discarded locally: no model connection, screen capture, file recording, history or memory learning. Native state owns status/errors and tokens; levels use the existing separate frame channel. Stop, timeout, navigation, window close/minimize, loss of focus during testing and voice startup release the test audio graph. Permission and stale-action fencing prevent delayed microphone reopening.
- Preserve grants, reviews, receipts and billing-route selection. No real calendar writes were used for verification.

## Verification

- Full native suite: 476 passed, 1 hardware test skipped, no failures (`build/VoiceInputVerification/VerifiedTests.xcresult`).
- Frontend tests/build and release verification are recorded in the release run.
- Native isolated fixture: microphone selection persisted, live test meter reached 32, Stop returned it to zero and showed the cancelled state. Browser preview inspected at 920 × 650 and 1440 × 900, including a long input name, keyboard focus and persistent device errors; no horizontal page overflow.
- Physical microphone/Continuity input routing and the reported macOS 26.6 machine remain unverified locally. Neither crash report includes the original throwing stack, so this change does not claim to prevent every native exception.
