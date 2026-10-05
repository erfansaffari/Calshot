# Calshot: macOS app plan

## Product

Calshot is a fast, native macOS utility for turning information visible on screen into a calendar event. The main loop is: press a configurable global shortcut, select a screen region, inspect a proposed event, edit it if needed, and save it to a chosen calendar.

## First release

1. A menu bar presence and a compact floating review panel anchored near the MacBook notch. On other Macs and external displays, the same panel should work below the menu bar.
2. A configurable global shortcut, plus a menu bar button, to capture the display under the pointer and select a rectangle. Show the cropped image immediately, with a clear way to retake or dismiss it. Frontmost-window capture remains a later option.
3. Local text recognition with Apple's Vision framework, followed by on-device AI interpretation where Apple Intelligence is available. OpenAI vision can cross-check the screenshot and OCR text when enabled. Fall back to the deterministic parser on other Macs. Extract likely event titles, dates, times, time zones, locations, and links into a draft. Preserve the recognized source text so people can check the proposal.
4. A review card that makes uncertain or missing fields obvious. Require a human confirmation before writing an event. Allow an all-day event and an explicit time zone.
5. Calendar destinations behind one interface. The first version supports both Apple calendars and Google calendars configured in macOS through EventKit. Direct Google sign-in can be added as a separate adapter after OAuth configuration is available; never write the same event to a synced Google calendar twice.
6. Ask for screen capture and calendar permissions in context. Save screenshot, OCR, and event history locally with per-item and clear-all delete controls. Keep credentials in Keychain.

## Architecture

```text
Global shortcut / menu bar
          |
          v
ScreenCaptureKit -> screenshot preview -> Vision OCR -> on-device AI / parser fallback
                                                 |                |
                                                 +-- source text -+
                                                                  v
                                                           review/edit panel
                                                                  |
                                              calendar destination protocol
                                                  /                  \
                                       EventKit adapter       Google API adapter
```

The event draft is independent of UI and calendar provider. It includes title, start, end, all-day status, time zone, location, URL, notes, source excerpt, and confidence/ambiguity flags. The parser should never silently invent a missing year or time without showing the assumption in review.

## Delivery order

1. Native app shell, menu bar control, top panel, global shortcut, and screenshot preview.
2. Local OCR and event draft extraction, with fixture-driven tests for date and time parsing.
3. Editable review and saving to a selected Apple or Google calendar configured in macOS.
4. Direct Google Calendar connection, if needed beyond calendars already configured in macOS.
5. Polish: motion, keyboard navigation, accessibility, onboarding, duplicate detection, and launch at login.

## Current build status

The native app shell, top review panel, configurable global shortcut, rectangular region selection, Vision OCR, optional on-device Foundation Models, OpenAI image/OCR analysis, editable review, EventKit saving, settings, and local screenshot/event history are implemented. Four parser fixtures pass in the Xcode test target. A manual run with macOS Screen Recording, OpenAI API, and Calendar permissions is still needed to verify the full capture-to-save flow on a real account. Direct Google OAuth, window capture, multi-event review, and deeper notch animation remain planned.

## Acceptance checks

- A shortcut captures visible content and opens the review panel promptly.
- A page with one clear date/time produces a correct draft; an ambiguous page asks for correction.
- An event appears exactly once in the selected calendar with the intended local time and time zone.
- Denied permissions show a useful recovery path.
- The panel works on a MacBook with a notch and on a display without one, in light and dark appearance, by mouse and keyboard.

## Open decisions

- Whether event creation should always require review or allow confidence-based automatic saving.
- Whether the user wants direct Google sign-in in addition to Google calendars configured in macOS.
- Cloud-assisted image understanding is available as an opt-in provider; on-device processing remains available.
