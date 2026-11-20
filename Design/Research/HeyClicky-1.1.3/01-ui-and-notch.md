# UI, notch, and windows

## Native ownership

The main bundle declares itself an agent-style macOS application through `LSUIElement` and links AppKit, SwiftUI and QuartzCore. The names and fields below come from the installed arm64 executable. The bundle also links WebKit, but the notch's own metadata identifies native panel and hosting layers. WebKit linkage by itself says nothing about which surface uses it.

| Layer | Build evidence | Architecture implication |
| --- | --- | --- |
| App state | `CompanionManager` owns permissions, voice state, transcripts, active jobs, window managers, drawing state, account context and the notch presenter | A central coordinator supplies the presentation state used by different surfaces |
| Presentation | `NotchPresenter` has a presentation enum, selected/expanded state, voice event holds, a pending collapse, composer focus, drag-open and document state | Presentation decisions are kept separate from view layout and window placement |
| Window lifetime | `NotchWindowManager` keeps instances keyed by display. `NotchScreenInstance` stores a panel, hosting view, state, envelope frame and last applied frame | Native per-display window identity is separate from the size and content shown inside it |
| View | `NotchRootView` observes presenter, companion manager and panel state, with hardware top inset and reduced-motion input | SwiftUI renders content against native window geometry |
| Rendering details | Native waveform and notch glow types include Core Animation layer variants. The binary links QuartzCore | Selected motion has dedicated rendering components instead of being solely driven by chat or window state |

No evidence establishes whether a hosting view is retained through every animation or how often the window frame actually changes.

## State and interaction

`NotchPresentation` distinguishes idle, live event, onboarding-pinned, text input and text response. `NotchLiveEvent` carries listening, thinking, speaking, dictation, agent activity, handoff, desktop-control consent, microphone trouble, document permission, settings/update and other notifications. These are multiple presentations within one coordinator. Their priority and preemption rules would require function-level traces.

- The presenter tracks a held voice event and an expiry task so a state can remain visible beyond the instant it changes. Composer focus, file drag, resize and holding an agent preview open also have their own state.
- Hover is driven by a dedicated scheduler with a pointer subscription, a slower housekeeping timer, a deadline timer and a trailing tick. The window manager tracks hover dwell, exit time, current expansion display and a persistent hover hit rectangle. The pointer source also has a native menu-tracking bridge. The exact polling frequency and dwell thresholds are unverified.
- The window manager subscribes to screen and Space changes, frontmost application activation, menu-bar overlap and Mission Control. It caches fullscreen probe state and tracks when to probe layout drift. The system overlay coordinator also remembers ownership and activation state when interacting with system windows.
- `ClickyNotchTabs` persists a selected surface, document path and thread, expanded reply, composer draft, attachments and focus request. It carries enough information to restore the prior tab when a document or reply closes.

## Chat, expanded workspace, and cursor

- Compact chat tracks pagination near the top, whether the user has moved away from the bottom, and the top row when window size changes. Separate views handle text replies, drawings, plans, artifact files and a job handoff. The expanded UI has its own transcript layout, including parsed rich text blocks and a memoized table layout. Several chat views carry a flag for opening their content in a window.
- The vendor describes the expanded window as a resizable workspace for personal and agent chat, documents and Settings. The 1.1.3 release also describes routing an in-progress typed answer to captions when the notch collapses. This is evidence for the marketed behavior, not a recording of the installed app. [Official release notes](https://www.heyclicky.com/changelog)
- Cursor motion is managed separately from the notch. `OverlayCursorPerformanceController` owns visual stages for bubble, navigation and body, with separate spring state, pointer subscription, generations for animation cancellation, and a pointing flight path. The system visibility monitor has a separate fullscreen probe. This structure lets the assistant marker travel independently of the OS pointer and notch UI.
- A shipped five-second clip shows shortcut use and a colored mark appearing over an anatomy image. It illustrates the visual concept, without proving live event ordering. [Packaged spatial demo](/Applications/HeyClicky.app/Contents/Resources/clicky-spatial-demo.mp4)

The user-facing UI was not opened. Account-gated tabs, platform-specific variants, actual focus transitions, and the visible status priority remain unverified.
