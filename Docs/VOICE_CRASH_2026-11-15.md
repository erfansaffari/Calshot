# Push-to-talk crash investigation (1.0.6 / 1008)

The supplied report is from an Apple Silicon Mac on macOS 26.6. The main thread faults in `swift_task_isMainExecutorImpl` while WebKit applies a remote layer-tree update. It also contains `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`, timestamped roughly 0.3 seconds before the crash. The original exception reason and throwing stack are absent. The report therefore does **not** establish that WebKit or audio is the original throw site.

A prior Objective-C exception unwinding Swift concurrency can leave executor state invalid; a later framework callback then detects the damage. A matching investigation is documented at https://github.com/manaflow-ai/cmux/issues/9553. This is evidence for the failure mechanism, not proof of Calshot's original throwing operation.

Voice startup previously called AVAudioEngine graph configuration, tap installation and prepare/start directly from Swift. These APIs can raise Objective-C exceptions, which Swift `do/catch` cannot catch. `VoiceAudioBoundary` now catches exceptions inside typed Objective-C operations, before they cross Swift frames. It also contains player scheduling/playing and graph cleanup failures. Do not change it to invoke a Swift-supplied operation block inside `@try`: that would still unwind Swift frames. Audio callbacks remain asynchronous and retain the existing session-generation fences.

Startup failures become the existing graph error, preserving fresh-graph voice-processing fallback, bounded retries, cancellation and the visible Sound-settings recovery route. Permission denial still bypasses retries. No credentials, calendar permissions, reviews or receipts change. Exception reasons are excluded from returned errors.

Regression tests inject exceptions from prepare, scheduling and stop without acquiring a microphone. Existing voice tests cover fallback/retry limits, stop during startup, stale sessions and review preservation. These tests establish containment and recovery behavior, not reproduction of the reported hardware failure.

Retest push-to-talk with the affected Mac's original input/output device pair and the new build. If it still fails, launch the executable under LLDB with `breakpoint set -E objc` to stop at the **first** Objective-C exception; record that throwing stack before continuing. Do not publish raw system logs, voice content or credentials. The original crash report alone cannot recover the missing exception.

## Local verification

- WebUI: 244 tests passed; production build passed.
- Clean Debug native build succeeded on macOS 26.5.2 / Xcode 26.2. Full native suite: 463 passed, 1 skipped, 6 failed. All three new `VoiceAudioBoundaryTests` passed, as did the voice-session tests. Failures are in PersonalMemoryTests and ContextEngineTests, with protected temporary memory files reporting permission errors (and consequent empty-memory assertions). Memory persistence was not edited; these failures remain unresolved in this change.
- Test result: `build/VoiceCrashVerification/Logs/Test/Test-Calshot-2026.11.15_16-35-31--0500.xcresult`.
- Launched the isolated `--voice-preview --compact-workspace` fixture. Computer Use could not inspect its window (`cgWindowNotFound`), so native visual inspection is incomplete. No browser inspection was performed; this patch has no web presentation changes.
- The reported macOS 26.6 device configuration has not been reproduced locally. No release was published or installed on the other computer.

## Release follow-up

The first 1.0.7 release attempt stopped at its native test gate; no installer was published. CI now prints the xcresult summary instead of hiding failure names behind Xcode's quiet output.

A standalone Foundation round trip reproduced the six local memory failures: `.completeFileProtectionUnlessOpen` created a temporary file that then failed to reopen with Cocoa error 257. `.completeFileProtectionUntilFirstUserAuthentication` passed the same write/read check. Personal memory now uses that protection class, retains atomic replacement and owner-only directory/file permissions, and still refuses to reset or overwrite an unreadable existing store. Existing persistence tests cover reopening saved memory and repeated replacements.

After the protection-class fix, the full local native suite passed: **469 passed, 1 skipped, 0 failures** (`build/release-verification/MemoryProtectionFix.xcresult`). This resolves the six local failures listed above. Device-specific crash reproduction and visual-inspection limitations remain unchanged.

The next release CI run passed 468 native tests and failed one pre-existing assertion that compared JSON strings with different object-key order. The separately run main-branch suite passed, confirming the ordering sensitivity. The assertion now decodes and compares the argument values, while retaining the persisted-history and tool-result checks.
