# Calshot

Calshot accounts use Supabase Auth with native Keychain sessions and a calendar-onboarding flow. The hosted sharing schema and authorization RPCs are deployed in Supabase. Google and email account sign-in use Supabase; Google login has been verified in the native app. After signup, users must choose a ChatGPT plan or API key before confirming calendars. Friends can share selected calendars through exact-email requests, with access enforced by the hosted service. The hosted service source is maintained privately.

Calshot is a native macOS menu bar app that turns screenshots and typed commands into a calendar agent workflow with explicit approval for changes. Press **Control–Shift–C** (customizable in Settings), drag over the event details, press Return, review the detected items, choose what to add, then approve additions to a writable calendar.

## Run

Open `Calshot.xcodeproj` in Xcode and run the **Calshot** scheme on a Mac, or use `./script/build_and_run.sh`. Calshot opens its review panel when launched and appears in both the Dock and menu bar.

The first capture asks for macOS Screen Recording permission. After the shortcut, drag to select the event information and press Return; Escape cancels. To save an event, choose a calendar in the review panel and grant Calendar access. Screen Recording approval requires a stable code signing identity: in Xcode, add your Apple ID under **Settings → Accounts**, then select its **Personal Team** for Calshot under **Signing & Capabilities**. Ad hoc signed debug builds may keep showing permission enabled in System Settings while macOS still rejects capture. If you switch to Apple Development signing and capture remains denied, remove the old Calshot entry under **System Settings → Privacy & Security → Screen & System Audio Recording**, add the current signed `.app` build, then quit and reopen Calshot.

## Calendar agent and action memory

Enable **OpenAI analysis** in Settings and connect an eligible ChatGPT plan or API key. A screenshot starts a tool loop; the command field can also start a session with text and the current screenshot. The agent can search connected readable calendars, request OCR, ask a question, and propose creating, changing, removing, or moving events. It pauses on an inline review card before every write. Removal rows start unchecked. Choose the calendar, inspect before/after values, and approve only the intended selection. **Skip pending** returns skipped results to the agent; **Stop** ends the loop and preserves completed writes.

The app streams assistant text, validates tool arguments, checks that changed/removed targets were searched, and passes actual calendar receipts back to the model. Missing details remain unresolved. Each session has at most eight model turns; new captures cancel the previous session. If the provider fails, on-device extraction remains available for screenshot-based new-event proposals.

Action memory lives in the same local history folder: version 3 records store user/assistant turns, tool names, arguments, actual results, and write receipts. Screenshot files are separate and their bytes never enter the saved transcript. Every turn includes the current conversation and tool results. Later sessions receive bounded recent action history, so the model can consider prior additions, edits, deletions, cancellations, and answers. Historical memory never authorizes another write; the agent must search current calendars and obtain new approval. Original screenshot context stays in the in-memory conversation for stateless `store:false` calls.

Open **History**, select a task, and choose **Continue this task** to review its conversation, outcomes, and screenshot. Restoring history does not replay old tools automatically. Deleting local history removes this context without removing calendar events. Changes to an entire recurring series, window capture, and automatic scrolling remain outside this release.

## Apple and Google calendars

Calshot lists writable calendars available through macOS Calendar. This includes Google calendars when a Google account has been added in **System Settings → Internet Accounts** and Calendar syncing is enabled. Choose the exact destination in the review panel. Direct Google sign-in is also available in Calendars after Calshot’s desktop OAuth configuration is saved.

## How event detection works

ScreenCaptureKit captures the display under the pointer, then the region selector crops the rectangle you chose. Local mode uses Vision OCR and, when available, Apple's on-device Foundation Models; a local parser is the fallback. Agent mode sends the captured image to the Responses API first. Vision OCR runs concurrently for history and source inspection; the model can request it with read_screen_text when needed. Turn it on from **Settings → AI & OCR**; region capture sends the chosen region; visible-screen capture sends the whole visible screen. Every candidate is editable and requires your approval before saving. Calshot retains all detected items, including assignments, deadlines, and tests. Unknown years, times, and durations are shown for review. Use group settings to confirm missing years or turn date-only deadlines into all-day events; timed tests still need a time. Calendar access is requested when you review or load calendars.

Calshot keeps capture history locally in **Settings → Memory**, including screenshots, OCR text, all proposals, edits, selection, and each calendar save receipt. Open a capture and choose **Review calendar actions** to resume it. Old single-event history remains readable. The default location is `~/Library/Application Support/Calshot/Memory`; Settings → Memory shows the full path, opens it in Finder, or moves the history to a folder you choose. Delete captures individually or clear the entire history from that tab. Deleting Calshot history does not delete calendar events.

To use an eligible ChatGPT Plus or Pro plan, open **Settings → AI & OCR** and choose **Continue with ChatGPT**. Sign in through the browser and separately approve plan usage for Calshot. Calshot keeps the resulting OAuth tokens in this Mac's Keychain, refreshes them locally, and sends selected screenshots directly to the Responses API with `store: false` and `stream: true`. Manage app limits in ChatGPT settings. This local personal-project integration does not share your ChatGPT conversations or API key. [OpenAI's local sign-in guide](https://developers.openai.com/siwc/token-sharing-open-source) describes eligibility and the flow.

An OpenAI API key remains optional. Paste it under **Settings → AI & OCR** and use **Test connection** to verify model access. API usage is billed separately by OpenAI. The key is stored in macOS Keychain. Do not commit or share it.

OpenAI API data is not used to train models by default. OpenAI's standard abuse-monitoring logs may retain request content for up to 30 days; `store: false` disables response-state storage, not all abuse-monitoring retention. See OpenAI's [data controls](https://developers.openai.com/api/docs/guides/your-data).

## Current limits

- The shortcut can be customized in **Settings → General**; the default is Control–Shift–C.
- **New Capture** supports selecting a region or capturing the visible screen. Window-only capture is not available yet.
- Screenshots contain visible pixels only. For a longer syllabus, scroll yourself and use **Add screenshot** to extend the same batch. Matching title/date/time items from overlapping captures are kept once; each item retains its source screenshot.
- **Review calendar items** opens the selectable list and editor. Select ready items, skip others, inspect source text, and approve the selected additions. Changes require a fresh duplicate check before approval.
- Possible duplicates require a decision. Saving shows individual results; successful items stay added, failed items can be retried, and **Stop remaining** leaves already completed additions in the calendar.
- Interrupted writes are checked against the original destination on reopening. Multiple possible matches require manual calendar review.
- Apple Intelligence availability depends on the Mac and system settings. The local parser covers common English date and time formats.
- OpenAI analysis requires either an authorized ChatGPT plan connection or an API key, plus internet access. If it fails, Calshot falls back to local analysis.
- ChatGPT plan sharing currently supports eligible accounts in local personal and open-source projects. A future paid or hosted Calshot needs separate eligibility and distribution review before using this connection.

See [CALENDAR_ACTIONS_PLAN.md](CALENDAR_ACTIONS_PLAN.md) for the batch workflow design and [PLAN.md](PLAN.md) for the original product plan.

## Verify the calendar workflow

Run the test suite with `xcodebuild test -project Calshot.xcodeproj -scheme Calshot -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData`.

For an offline native UI fixture, build Debug and launch `open -n build/DerivedData/Build/Products/Debug/Calshot.app --args --calendar-demo`. This uses a demo calendar service and temporary capture history, without writing to real calendars. Restart normally to return to the real app. The demo is excluded from Release builds.

To exercise the full agent flow without model credentials or real calendar writes, launch the Debug build with `--calendar-agent-demo`. The scripted fixture asks a question, proposes a batch, waits for approval, and summarizes only its actual demo receipts. Follow-up “move the midterm” or “delete the midterm” commands exercise searched targets and individual approvals.

Chat has its own sidebar section. Commands, streamed replies, tool results, and restored conversations remain visible there; calendar approvals stay in Capture. Failed HTTP handshakes (including 520) retry up to twice before on-device extraction. Chat shows persistent errors and a manual Retry action. When both a ChatGPT plan and an API key are connected, “Retry with API key” explicitly switches subsequent requests to separately billed API usage for this app session. A failed model turn after a write receipt does not re-extract the screenshot.

Chat searches all connected calendars and lets you choose a writable destination for new events. Results identify the checked calendars and exact range even when no events are found. Browser-only accounts need a direct connection in Calendars or an existing macOS account. The selected create destination is remembered across app launches. AI settings offer a plan-connection check and preserve upstream error details and request identifiers. A failed plan-token refresh does not silently switch to separately billed API usage.

The Calendars section supports direct Google and Outlook/Microsoft 365 account sign-in with desktop OAuth + PKCE. Calendar API / Microsoft Graph operations use Keychain-backed tokens and refresh. Configure Calshot's registered OAuth client IDs once in Connection setup. Google requires its desktop client secret for authorization-code exchange and refresh; store it in Keychain using the secure setup field. The app checks setup before opening sign-in. Credentials are never included in model requests or checked into the repository. Searches cover every connected source, include read-only calendars, report denied sources as partial failures, and deduplicate matching iCalendar UIDs per occurrence. Confirmed calendar transport aliases reuse an existing macOS calendar. Updates/deletes are bound to their original calendar. Notion Calendar uses its underlying Google/iCloud/Microsoft accounts. Direct iCloud uses CalDAV discovery and an app-specific password in Keychain; recurring instances are expanded by the server and individual changes use recurrence overrides plus ETag checks. Live iCloud connection verification remains pending.


## Workspace design and development

The main workspace uses React, TypeScript, Radix Dialog and Lucide inside a native WKWebView. Swift remains authoritative for capture, permission prompts, Keychain, account connections, agent tools, validation, write approvals and action history. The menu bar and notch shell remain native; the notch embeds the same React questions, reviews and editors as the workspace.

Read [AGENTS.md](AGENTS.md) and [Design/DESIGN_SYSTEM.md](Design/DESIGN_SYSTEM.md) before changing product behavior or UI. [Calshot.html](Calshot.html) is the designer's original nine-board reference and is preserved unchanged. Shared UI tokens live in WebUI/src/tokens.css; reusable controls live in WebUI/src/components.

Install Node.js/npm before building. Xcode runs script/build_web_ui.sh, builds the frontend and packages it into the signed app. For frontend-only work run npm ci and npm run dev in WebUI. The browser preview requires an explicit ?preview=1 query and uses fictional data only; append &scenario=home, &scenario=syllabus, &scenario=partial or &scenario=question for state coverage. Without native services or explicit preview mode the interface reports an unavailable connection; it never substitutes demo calendar successes.

Run npm test and npm run build in WebUI, and run the Calshot Xcode test suite for native/bridge changes. Debug launches support --calendar-agent-demo for an isolated scripted agent/calendar and --compact-workspace for a 920 × 650 workspace. Do not verify writes against real calendars.

The bridge accepts only known actions from the bundled main page, excludes tokens and tool payloads from presentation state, binds questions to their IDs, and checks a current review token before edits, selection, skipping or approval. Calendar outcomes still come from coordinator receipts. Native advanced preferences remain available for connection registration and storage configuration.


### Appearance and notch quick menu

Settings → Appearance offers System, Light and Dark. System follows live macOS appearance changes; the saved choice controls React surfaces, native preferences and screenshot window chrome. The expanded notch follows the same appearance, while the camera bezel/status strip stays black.

Hover over the notch for the compact Capture / Ask bar. Capture and the global shortcut save a screenshot first; add optional instructions and choose Add to calendar to start the agent. Questions, source inspection, batch review, event editing, approval, partial retries and follow-up conversation stay in the notch. Clean create batches offer Add all; updates, moves and unchecked deletions use inline review. Working collapses to a small status strip with Stop available on expansion. Command–Shift–K opens the notch with keyboard focus; Escape closes an editor, details or the panel in order. Hover and background progress do not take keyboard focus. The pop-out button opens the optional full workspace. Activity notifications, including pending reviews and errors, hide after four seconds without clearing the task. Moving outside the notch closes it even after clicking or typing; return to hover for the pending task and unfinished edits. Background progress never opens it. Completion feedback uses write receipts. The shell respects camera safe areas; expanded content follows System, Light or Dark.

### Calendar and Settings

Calendar follows the updated HTML reference with Day, Week (default), and Month views, a sidebar mini month and colored calendar filters, a compact date toolbar and an Ask Calshot field. Calendar questions start a fresh conversation; Assistant messages continue the current one. Two-finger horizontal swipes over the board move one day, week or month in the selected view, while vertical gestures scroll the schedule. The timetable separates all-day events, lays overlapping events in lanes and expands for early/late events. Event details open in a compact card. The + form asks for explicit date/time or all-day intent, then prepares the event through Assistant and its approval review. Visibility filters never change the default destination. Navigation and Refresh issue bounded native reads; source failures and truncation remain visible. Sharing controls will be added with the real accounts integration.

Settings is grouped into General, Calendar accounts, AI service, and Privacy & permissions. Manage accounts and the sidebar connection status open Calendar accounts, where existing connection, default destination, reconnect and disconnect controls are preserved.

## Hosted website and service

The Mac client source is public; a license has not yet been chosen. This repository contains the Mac client and its shared presentation components. The hosted website, download landing page, account service, cloud worker and database implementation are maintained in a separate private repository. They are excluded from this checkout’s public Git index. The Mac app uses the hosted account and sharing contracts; calendar credentials, agent sessions and write approval stay native.

Developers working on both products may have ignored local links named `Website`, `Backend` and `supabase`. They are private development conveniences and are not part of the client repository. The private website pins this public client as a submodule so presentation components retain one implementation.

## Automatic software updates

The Mac app uses Sparkle with a signed GitHub Releases feed and Settings → General update controls. See [UPDATES.md](UPDATES.md) for release signing, notarization, GitHub Actions setup and current distribution limitations.
