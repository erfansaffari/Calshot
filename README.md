# Calshot

Calshot is a native macOS menu bar app that turns a selected part of your screen into a calendar event draft. Press **Control–Shift–C** (customizable in Settings), drag over the event details, press Return, review the detected details, then save to a writable calendar.

## Run

Open `Calshot.xcodeproj` in Xcode and run the **Calshot** scheme on a Mac, or use `./script/build_and_run.sh`. Calshot opens its review panel when launched and appears in both the Dock and menu bar.

The first capture asks for macOS Screen Recording permission. After the shortcut, drag to select the event information and press Return; Escape cancels. To save an event, choose a calendar in the review panel and grant Calendar access. Screen Recording approval requires a stable code signing identity: in Xcode, add your Apple ID under **Settings → Accounts**, then select its **Personal Team** for Calshot under **Signing & Capabilities**. Ad hoc signed debug builds may keep showing permission enabled in System Settings while macOS still rejects capture. If you switch to Apple Development signing and capture remains denied, remove the old Calshot entry under **System Settings → Privacy & Security → Screen & System Audio Recording**, add the current signed `.app` build, then quit and reopen Calshot.

## Apple and Google calendars

Calshot lists writable calendars available through macOS Calendar. This includes Google calendars when a Google account has been added in **System Settings → Internet Accounts** and Calendar syncing is enabled. Choose the exact destination in the review panel. A direct Google OAuth sign-in and Calendar API connection are not enabled yet.

## How event detection works

ScreenCaptureKit captures the display under the pointer, then the region selector crops the rectangle you chose. Local mode uses Vision OCR and, when available, Apple's on-device Foundation Models; a local parser is the fallback. OpenAI mode sends the selected screenshot region and its recognized OCR text to the Responses API and asks for structured event details. Turn it on from **Settings → AI & OCR**; only selected regions are sent when OpenAI mode is enabled. Every candidate is editable and requires your confirmation before saving.

Calshot keeps capture history locally in **Settings → Memory**, including the selected screenshot, OCR text, event proposal, and whether you added it to a calendar. The default location is `~/Library/Application Support/Calshot/Memory`; Settings → Memory shows the full path, opens it in Finder, or moves the history to a folder you choose. Delete captures individually or clear the entire history from that tab. Deleting Calshot history does not delete calendar events.

To use an eligible ChatGPT Plus or Pro plan, open **Settings → AI & OCR** and choose **Continue with ChatGPT**. Sign in through the browser and separately approve plan usage for Calshot. Calshot keeps the resulting OAuth tokens in this Mac's Keychain, refreshes them locally, and sends selected screenshots directly to the Responses API with `store: false` and `stream: true`. Manage app limits in ChatGPT settings. This local personal-project integration does not share your ChatGPT conversations or API key. [OpenAI's local sign-in guide](https://developers.openai.com/siwc/token-sharing-open-source) describes eligibility and the flow.

An OpenAI API key remains optional. Paste it under **Settings → AI & OCR** and use **Test connection** to verify model access. API usage is billed separately by OpenAI. The key is stored in macOS Keychain. Do not commit or share it.

OpenAI API data is not used to train models by default. OpenAI's standard abuse-monitoring logs may retain request content for up to 30 days; `store: false` disables response-state storage, not all abuse-monitoring retention. See OpenAI's [data controls](https://developers.openai.com/api/docs/guides/your-data).

## Current limits

- The shortcut can be customized in **Settings → General**; the default is Control–Shift–C.
- Capture currently supports a selected region; window-only capture is not available yet.
- The first review card shows one proposed event at a time. Pages with multiple events need a future multi-event picker.
- Apple Intelligence availability depends on the Mac and system settings. The local parser covers common English date and time formats.
- OpenAI analysis requires either an authorized ChatGPT plan connection or an API key, plus internet access. If it fails, Calshot falls back to local analysis.
- ChatGPT plan sharing currently supports eligible accounts in local personal and open-source projects. A future paid or hosted Calshot needs separate eligibility and distribution review before using this connection.

See [PLAN.md](PLAN.md) for the product plan and next steps.
