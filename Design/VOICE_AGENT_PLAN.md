# Voice agent, focus drawing and persistent memory

Status: approved direction, 2026-10-29. Extends [AGENT_PLATFORM_PLAN.md](AGENT_PLATFORM_PLAN.md) and [PROACTIVE_PLANNING_IMPLEMENTATION.md](PROACTIVE_PLANNING_IMPLEMENTATION.md); it does not change their permission, receipt or recovery contracts. Read [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) and the project AGENTS.md first.

## Product

A second way to work with Calshot, next to Capture and the notch. Press the voice shortcut and talk. Calshot listens, can see the screen, and replies by voice with short spoken answers. Point at or draw on anything you want it to focus on. A calendar or task change still appears as a review in the notch (or the pop-up when the notch is off) and is approved by a click or keyboard, never by voice alone.

Decisions made by the owner on 2026-10-29:

- **Voice engine:** OpenAI Realtime (speech-to-speech, interruptible). It needs an OpenAI API key; it is not available on the ChatGPT plan route. The UI says so before the first session and never switches billing silently. Without a key, voice mode explains how to add one and does nothing else.
- **Screen view:** one frame per utterance or drawing, never continuous video. Frames are taken only while a voice session is on and a visible indicator is shown.
- **Memory:** explicit memories plus suggestions the user approves. Local to this Mac. Inspect, edit and forget in Settings.

## Experience

1. **Start:** voice shortcut (default ⌃⇧V, configurable next to the capture shortcut) or the mic button in the notch. The notch shows a listening state with a live level meter; if the notch is off, a small floating pill appears at the top center.
2. **Talk:** server voice activity detection ends a turn. Barge-in: speaking while Calshot talks stops its audio immediately.
3. **Focus drawing:** hold ⌥ (or press D in the session) to draw. A transparent overlay on the display under the pointer captures strokes; the ink animates in with a soft glow and fades slowly. Click without dragging drops a pulsing point. Releasing ⌥ returns clicks to the apps below. Strokes are sent with the next frame as normalized boxes and drawn into the image.
4. **Answer:** short spoken reply plus a one-line caption in the notch. Longer content (lists, event details, reviews) opens the notch detail or the pop-up; voice says "I put it in the notch".
5. **Changes:** proposals use the existing review cards and approval token. "Yes" spoken aloud is never approval; the review shows ⏎ Approve / ⎋ Skip and the voice says "Press Return to add them".
6. **End:** shortcut again, Esc, 60 s of silence, or the session limit. The indicator disappears and no more frames or audio are sent.

## Architecture

Swift owns audio, capture, credentials, the Realtime connection, tool execution and memory. React presents state through the existing snapshot/command bridge.

- `Sources/Voice/RealtimeVoiceClient.swift` — WebSocket transport to the Realtime API: session config, PCM16 audio in/out, image input, function calls, interruption, reconnect, usage accounting. A `RealtimeTransport` protocol lets tests replace the socket.
- `Sources/Voice/VoiceAudioEngine.swift` — AVAudioEngine microphone capture with voice processing (echo cancellation), resampling to 24 kHz PCM16, playback queue with immediate flush on barge-in, input level metering, device-change handling.
- `Sources/Voice/FocusOverlayController.swift` — borderless non-activating overlay panel per display, stroke capture and animation, pass-through when not drawing, Esc handling.
- `Sources/Voice/FocusFrameComposer.swift` — captures the active display excluding Calshot's own windows (ScreenCaptureKit), scales to at most 1280 px on the long edge, draws strokes, returns JPEG data plus normalized stroke boxes.
- `Sources/Voice/VoiceSessionController.swift` — the session state machine (idle → connecting → listening → thinking → speaking → waiting for review → ended/failed), limits, indicator, tool routing into the existing `CalendarAgentToolExecutor`, notch/pop-up presentation.
- `Sources/Memory/PersonalMemoryStore.swift` — versioned, account-scoped local store (JSON file with atomic writes, 0600 permissions) of memory items: kind (preference, fact, person, routine), text, origin (explicit/suggested-approved), source reference, created/updated, optional expiry, and forget tombstones that prevent re-creation from retained history.
- `Sources/Memory/MemoryContextBuilder.swift` — selects a bounded context package (token budget) of relevant memories for a request; used by both the text agent and voice sessions.

Tools available to the voice model are the existing calendar/task tools plus `remember` (creates a *suggested* memory that the user approves in the notch) and `recall`. The model never receives credentials, approval tokens or raw provider identifiers it does not need.

## Cost and limits

- Default Realtime model is the current general-availability realtime model; the model ID is a setting, not hard-coded in several places.
- Audio streams only while a session is active. Frames are JPEG ≤1280 px, one per user turn or drawing, never on a timer.
- Session cap 10 minutes, idle stop after 60 seconds, and a per-session usage meter (audio seconds and estimated cost) in the notch detail. A monthly soft cap in Settings stops new sessions when reached.
- Memory context is capped (default 1,500 tokens) and only relevant items are sent.

## Edge cases

Permissions: microphone denied or restricted, Screen Recording missing, notifications irrelevant; each shows its own fix next to the voice controls. Hardened-runtime release builds need the audio-input entitlement and `NSMicrophoneUsageDescription`.

Audio: Bluetooth headset switching mid-session, no input device, echo from speakers, noisy room, the user talking over Calshot, very long monologues, silence.

Network/API: missing or invalid key, rate limits, server errors, socket drop and reconnect with conversation state, slow first audio, unknown model ID.

Screen: multiple displays and Spaces, full-screen apps, Retina scale, the overlay itself must not appear in frames, secure input fields, the notch disabled, capture during Stage Manager.

Agent: interrupted tool call, review pending when the session ends (review stays in the notch), a second session started while one is running, account switch or sign-out mid-session, Stop preserving completed writes, spoken approval attempts, prompt injection in on-screen text.

Memory: duplicate or conflicting memories, forgetting a memory that is still in history, editing while a session uses it, account switch, corrupted file (kept, error shown, never overwritten).

## Delivery and assignments

Work runs in separate worktrees with disjoint files. Stub files and Xcode membership are created up front so agents never edit the project file.

| Step | Owner | Files |
| --- | --- | --- |
| A. Memory store, context builder, Settings memory UI | GPT-6.1 Sol (implementation) | `Sources/Memory/*`, `Tests/PersonalMemoryTests.swift`, memory parts of the bridge and Settings |
| B. Realtime transport and audio engine | GPT-6.1 Sol (implementation) | `Sources/Voice/RealtimeVoiceClient.swift`, `Sources/Voice/VoiceAudioEngine.swift`, `Tests/RealtimeVoiceClientTests.swift` |
| C. Focus overlay and frame composer | GPT-6.1 Sol (implementation) | `Sources/Voice/FocusOverlay*.swift`, `Sources/Voice/FocusFrameComposer.swift`, `Tests/FocusOverlayTests.swift` |
| D. Session controller, shortcut, notch/pop-up UI, entitlements | After A–C merge | `Sources/Voice/VoiceSessionController.swift`, app/notch/WebUI integration |
| Tests and edge-case sweeps | GPT-6.1 Sol (testing) | test files per step |
| Security and permission review | Claude Sonnet 5.5 (review) | read-only |

Gates: each step builds, its tests pass with mocks (no real network, microphone or calendar writes), and the full native and WebUI suites still pass. A real voice session is verified last, with fictional data and the owner's explicit go-ahead because it uses the paid API.
