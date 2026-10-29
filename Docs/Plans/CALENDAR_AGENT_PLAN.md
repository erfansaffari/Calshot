# Calendar agent implementation

Calshot will run a bounded model → tool → result loop for screenshots and typed commands. Read tools execute immediately; create, update, and delete tools suspend on the existing native review screen. The model receives real execution receipts and continues after approval or skipping. Eight model turns is the limit. Stop cancels future work and pending interactions; completed writes remain recorded.

The Responses client sends the screenshot on the first turn, offers only six validated tools, streams assistant text, and executes calls only after complete arguments arrive. Vision OCR runs concurrently and is available through read_screen_text, source inspection, and the Foundation Models/parser fallback. Credentials and store:false remain as today.

The calendar layer adds selected-calendar search, scoped event lookup, single-occurrence update and delete. The proposal model gains operations and before snapshots while missing operations in old history decode as create. Journaling remains mandatory before calendar writes. Recovery uses event identifiers and exact draft comparisons for updates, and absence of the target for deletes.

Memory schema version 3 stores agent turns separately from image bytes. Every new model request includes the conversation's real tool results; later sessions additionally receive bounded recent action receipts from local history. Reopening Memory restores the transcript and proposals. Historical actions inform the model but never authorize a new write. Calendar search remains the source of current event truth. Incomplete historical tool calls are not automatically re-executed.

Implementation ownership: one sub-agent implements runner/client and scripted model tests; one implements proposal/calendar/coordinator operations and recovery tests; one implements native conversation, questions, operation review, and status UI. The main agent implements tool validation/dispatch, app integration, persistence/context retrieval, project registration, integration tests, and verification.

Verification includes the requested scripted sequences, skipped deletes, disambiguation before updates, failure-only retries, the eight-turn limit, late-result cancellation, update recovery, and legacy decoding. Build/test and an isolated native demo precede any account-based manual pass. A real permission or account blocker will be reported rather than silently changing permissions or creating calendar test entries.

Direct Google OAuth, series-wide recurring changes, automatic scrolling, and window capture are outside this release.

## Implementation status

The runner, streaming Responses client, six validated tools, create/update/delete approval flow, command/questions UI, transcript persistence, bounded cross-session action memory, and safe Memory resume are implemented. Tests cover scripted model sequences, real executor dispatch against a fake calendar, receipt recovery, legacy operation decoding, and action-memory round trips. Native smoke verification uses an isolated scripted model/calendar service. Live provider and EventKit permission verification are reported separately.

Verification result: 52 automated tests passed and the signed Debug app built/launched successfully. Native isolated UI verification covered question → create approval → actual receipt summary, follow-up searched update with before/after review, and visible saved action history. A live session visible in Memory successfully searched today's and tomorrow's ranges and persisted both results. Real create/update/delete writes on a dedicated test calendar and the Screen Recording manual pass remain pending.
