# Calshot

Calshot is a native macOS menu bar app that turns a screenshot into a calendar event draft. Press **Control–Shift–C**, review the detected details in the top-of-screen panel, then save to a writable calendar.

## Run

Open `Calshot.xcodeproj` in Xcode and run the **Calshot** scheme on a Mac. Calshot opens its review panel when launched and appears in both the Dock and menu bar.

The first capture asks for macOS Screen Recording permission. To save an event, choose a calendar in the review panel and grant Calendar access. Screen Recording approval requires a stable code signing identity: in Xcode, add your Apple ID under **Settings → Accounts**, then select its **Personal Team** for Calshot under **Signing & Capabilities**. Ad hoc signed debug builds may keep showing permission enabled in System Settings while macOS still rejects capture. If you switch to Apple Development signing and capture remains denied, remove the old Calshot entry under **System Settings → Privacy & Security → Screen & System Audio Recording**, add the current signed `.app` build, then quit and reopen Calshot.

## Apple and Google calendars

Calshot lists writable calendars available through macOS Calendar. This includes Google calendars when a Google account has been added in **System Settings → Internet Accounts** and Calendar syncing is enabled. Choose the exact destination in the review panel. A direct Google OAuth sign-in and Calendar API connection are not enabled yet.

## How event detection works

ScreenCaptureKit captures the display under the pointer. Vision reads text locally from the screenshot. On macOS 26 with Apple Intelligence available, Apple's on-device Foundation Models interprets the recognized text into event candidates. A local parser provides a fallback. Every candidate is editable and requires your confirmation before saving. Screenshots are held in memory for the review session and are not saved by default.

## Current limits

- The shortcut is currently fixed at Control–Shift–C.
- Capture uses the whole display under the pointer; selecting a region or a window is planned.
- The first review card shows one proposed event at a time. Pages with multiple events need a future multi-event picker.
- Apple Intelligence availability depends on the Mac and system settings. The local parser covers common English date and time formats.

See [PLAN.md](PLAN.md) for the product plan and next steps.
