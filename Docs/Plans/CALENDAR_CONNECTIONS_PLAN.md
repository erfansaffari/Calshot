# Calendar connections and unified search

Requested behavior: Calshot searches every connected calendar, connects accounts inside its own UI, and reuses an already-connected calendar instead of importing a second copy. New events go to an explicit writable destination; updates/deletes stay bound to the original event's calendar. Every write requires review.

## Implemented foundation

Search every EventKit calendar, including read-only calendars. Return the exact interval, per-calendar success/error, partial/truncated flags, and calendar identity. Never interpret a failed source as an empty source. Keep a change bound to its original calendar even if the default destination changes. Remember the default create destination. Surface plan-route errors separately from calendar access.

## Account adapters

- Apple/local: existing EventKit calendars are reused. Direct iCloud access needs CalDAV discovery and an app-specific password; never request an Apple ID password.
- Google (implemented; Desktop client registered and API enabled; test-user setup/live consent pending): desktop OAuth authorization code + PKCE + loopback callback, Calendar API calendar list and event operations, Keychain token storage and refresh.
- Outlook/Microsoft 365 (implemented; registration/live consent pending): public desktop OAuth + PKCE, personal and organizational accounts, Graph calendar list/calendarView and event operations, Keychain tokens and refresh.
- Notion Calendar: connect the underlying Google, Apple/iCloud, or Microsoft accounts. Do not create a parallel Notion event store. Notion database dates are outside the requested scope.

## Identity and duplicates

Use provider + account identity + provider calendar ID for canonical calendar identity. Track transport aliases (EventKit/direct API), selecting one transport for each canonical calendar. Event deduplication requires a provider identity or iCalendar UID plus occurrence identity; matching a title/time alone must not silently hide unrelated events. An uncertain transport match is shown for user confirmation before merging. Writes use one transport, never both.

## Registration setup

Create a dedicated Calshot Google Cloud project; enable Calendar API; configure consent/testing; register a Desktop OAuth client. Microsoft: register a public desktop app supporting personal and work/school accounts, loopback redirect, delegated Calendar access, and offline refresh. Client IDs identify Calshot and are entered once in app configuration; token values stay in Keychain. New access/consent grants require the user to approve the provider's consent screen.

## Verification

Scripted provider responses must cover pagination, recurrence instances, timezones/all-day events, partial failures, refresh, cancelled consent, duplicate transport identities, uncertain aliases, and keeping updates/deletes on the original source. A live test connects a disposable calendar through each configured provider, discovers an existing macOS alias, and verifies one search result and one approved write.

## Current registration state

A dedicated Google Cloud project `calshot-511605` is available, with Google Auth Platform configuration created. The Desktop OAuth client is registered and its public client ID is configured in the app. Calendar API is enabled after explicit approval. Successful consent still needs verification; the attempted live Google connection was cancelled by the user. Microsoft registration requires portal sign-in and an app client ID. Neither account flow is declared live-verified until provider consent succeeds. Direct iCloud CalDAV is implemented with secure discovery, Keychain app-specific passwords, ETag checks, and single-occurrence overrides. Live verification needs the user to enter an app-specific password in the app.

The native live search now checks eight macOS-connected calendars and finds three events on October 15, 2026 in Waterloo, with no read failures. The previous empty result searched only the default Calendar. The ChatGPT plan request still returns HTTP 520 with Cloudflare request reference `a4a445ca2a32a392-YYZ`; the API-key request succeeds. The plan-route root cause remains unconfirmed.

Google Calendar API enablement is verified in the Calshot project, and the public Desktop client ID ships as the default configuration. Microsoft app registration uses a public native client with `http://localhost/auth/callback` (ephemeral port matching). The portal reports app-registration access denied for the Waterloo tenant. The user explicitly requested leaving Outlook registration pending. No registration, access request, or privilege change was attempted in that tenant.

Google Audience is External / Testing with one test user, `erfansaffari0@gmail.com`, added and verified after explicit approval. Provider calendar consent still needs completion in the app. The latest build launches successfully and shows all eight native calendars, with Outlook connection disabled until its client ID exists. The latest automated suite passes 74 tests. A fresh plan model-catalog check also returns HTTP 520, so the plan failure affects more than screenshot inference.

## Google missing-secret fix and connection UI

Google's desktop token exchange returned HTTP 400, `client_secret is missing`. Authorization-code and refresh requests now require and include the matching desktop client secret from a separate Keychain item. Missing setup stops before browser sign-in. The secret never enters model context, preferences, transcripts, or source code. A regression test verifies both grants, form encoding, retained PKCE, and the Microsoft public-client path.

The Calendars page now uses account cards, explicit macOS/direct status, an available-calendar list, a new-event destination picker, contextual errors/cancellation, a disconnect confirmation, and collapsed developer setup. Existing Google/iCloud connections remain active; Outlook registration remains pending. All 75 tests passed; subsequent status/scroll UI refinements build and launch successfully.

Google Cloud no longer reveals or downloads the existing secret. Local download discovery found no saved credential JSON. The user created a replacement credential and approved saving it in Keychain. The credential is saved separately from source/preferences, and Calshot verifies Direct sign-in: ready. The repaired Google sign-in completed successfully after the user's consent; both Google calendars were discovered live. Waterloo and the primary Google calendar were linked to their existing macOS entries, leaving eight available calendars with no duplicate transport entries.

## Transfer and question layout fix

The interrupted October 20/22 shift transfer had already added two Google copies; Apple originals remained. The app sample showed the main thread spending nearly all of its time in SwiftUI layout measurement while showing a long four-choice question. Replaced horizontal/vertical ViewThatFits choices with vertically wrapped buttons and a fixed-height scrolling question card. An isolated demo recreated the exact question, accepted an answer, and finished without any calendar writes.

Added move_events for a searched group with one review, explicit source/destination, and optional reuse of searched destination copies. Writes persist the destination copy receipt before source removal, verify the copy, recheck the original, and retain originals on failure or Stop. Missing details on reused copies are restored only when their reviewed snapshot still matches. Interrupted transfers recover their copy identifiers and require approval to remove remaining originals. create_events can bind a calendarIdentifier from the user's chosen destination; review no longer asks to choose that destination again.

All 83 tests pass, including two-event batching, copy/delete failures, retry without duplicate copying, interrupted-copy recovery, reuse of existing copies, restoring original notes, and Stop after copying. The original transfer conversation is restored for a fresh search and a single review; no automated approval is performed.
