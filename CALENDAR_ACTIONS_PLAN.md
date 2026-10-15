# Screenshot-to-calendar action planning

## Implementation status

Implemented: calendar proposals and shared validation; preserving multiple candidates; batch summary/list/editor and group confirmation; source evidence and OCR regions; serial approval/execution, stop, selective retry, duplicate checks and durable receipts; legacy history migration and reopening; additional screenshots with overlap deduplication and per-item image references; visible-screen capture; isolated Debug UI fixture and automated tests.

Validation covers deterministic syllabus fixtures and a fake calendar service. Live OpenAI/Foundation Models extraction quality and real EventKit writes still need account-based manual verification. Duplicate matching currently uses normalized title plus start/end and all-day status; semantic title variations may require human review. Recovering an interrupted write uses exact matching in its original calendar, with ambiguous matches left for review. Automatic scrolling, imported documents, direct Google OAuth, and existing-event changes remain outside this release.

## Intended experience

Capture a syllabus or schedule once. Calshot reads all visible assignments, quizzes, and exams, then offers a concrete proposal: “Found 12 calendar items: 8 assignment deadlines and 4 tests.” The user can inspect the source, edit details, select or skip items, and approve the chosen additions. Nothing is written until that approval.

First-release scope: propose and create multiple calendar events in the existing EventKit calendars, including Google calendars synced through macOS. Updating or deleting existing events, direct Google OAuth, browser automation, and unrelated actions are later work.

A screenshot covers only captured pixels. The first version processes a large selected region or visible screen/window content; it must not claim to have read content below the viewport. Add-more-captures into one proposal is a follow-up. Automatic scrolling or PDF import is a separate feature.

## What already exists

- `OpenAIEventAnalyzer` and the Foundation Models path return arrays of drafts.
- `CalshotModel.analyze` keeps only `candidates.first`; the remaining candidates never reach review.
- The deterministic parser returns one draft for the entire OCR text and flags multiple dates. It needs row/block segmentation before it can support a schedule reliably.
- `UnifiedWorkspace.swift` edits one draft with one global saving status.
- `MemoryStore` stores one event and one calendar receipt per capture.
- `EventKitCalendarService` saves one event and suppresses repeated saves by draft ID only within the running process.
- OCR currently returns a flat string, losing the layout useful for associating table columns and highlighting evidence.

## Product flow and UI

1. **Capture and analyze.** Show the image immediately, with stages such as “Reading screenshot” and “Finding calendar items.” Allow cancellation and retaking. A cancelled or superseded request cannot replace the current proposal.
2. **Offer an action.** Present a summary and “Review calendar items.” An empty result offers retake and manual entry. A provider fallback or incomplete extraction remains visible beside the summary.
3. **Review a batch.** Use a date-sorted list with selection checkboxes, item type, title, date/time, and readable status: Ready, Needs review, Possible duplicate, Skipped, Added, or Failed. Ready items start selected; unresolved items require attention before selection for saving. Keep skipped items recoverable.
4. **Edit an item.** A detail pane exposes title, date, all-day/time, duration, timezone, location, URL, and notes. Show its source excerpt and, when coordinates are available, the corresponding screenshot region. Group controls cover destination calendar, course prefix, confirmed year, and explicit conversion of date-only deadlines to all-day entries.
5. **Approve the exact selection.** A persistent footer shows “Add 9 items to School,” the selected count, and unresolved count. The add button is the approval; a second modal is unnecessary. No blanket “approve all” should hide unresolved assumptions. “Cancel review” discards pending proposals without touching the calendar.
6. **Execute and report.** Update progress per item. Show “8 added, 1 failed”; preserve failures and allow retrying only those items. Stop cancels remaining writes, while clearly showing completed additions. After execution starts, cancellation cannot erase events already saved.

At wider widths, show the event list and editor beside the screenshot/source inspector. At smaller widths, use a list with an expandable editor and source drawer. Avoid giving the screenshot a fixed 390-point height that pushes batch controls away. Keep the approval footer visible while scrolling. Extract small SwiftUI components so new action types can reuse the review shell later. Provide keyboard selection, Space to select, Return to edit, and Escape to leave an editor without approving anything; support VoiceOver and native focus.

## Domain and execution design

Use a bounded analyze → propose → review → execute workflow. A general autonomous agent loop is unnecessary for calendar creation, but the proposal boundary should allow other action types later.

- **CaptureAnalysis:** capture/session ID, page/course context, provider, completeness notices, and candidates.
- **CalendarActionProposal:** stable ID, operation (`createEvent` initially), editable EventDraft, kind (deadline/exam/class/other), evidence, field assumptions, selection, destination, and review status.
- **CalendarActionBatch:** proposal collection, selected IDs, batch defaults, and workflow state. Keep proposal data separate from transient UI focus.
- **CalendarActionReceipt:** proposal ID, destination ID, calendar event ID, save timestamp, and result/error. Persist receipts individually to support recovery and retry.
- **Coordinator:** owns cancellation, validation, duplicate checks, approval snapshots, and execution. Move this logic out of the expanding CalshotModel; the model exposes state to SwiftUI.

Derive Ready/Needs review from shared validation rather than independently in each view. At approval, freeze the selected drafts and destination into an execution snapshot; subsequent edits or a new capture cannot alter the running save. Block simultaneous execution of the same batch.

## Extraction rules for syllabi

- Preserve table rows and nearby headings when pairing an assignment with its date. OCR results should retain normalized bounding boxes and recognized lines alongside the existing text representation.
- Extract item-specific evidence rather than attaching the entire page as each event's source.
- Use explicit semester/course context to resolve a year, and record that inference. If no reliable year is available, ask for one batch-wide confirmation; do not silently use the current year.
- Distinguish a deadline from a timed exam. Date-only deadlines can become all-day events after the user accepts that policy. A stated submission time remains a timed deadline with an explicitly reviewed calendar duration, not an invented one-hour class.
- Missing exam times and missing durations remain visible. Date ranges, contradictory weekday/date pairs, ambiguous numeric dates, and “TBD” must not become silently confirmed dates.
- Do not turn weights, week numbers, unrelated navigation dates, or a “subject to change” notice into events. Surface schedule qualifications as notices.
- Ensure Foundation Models validation operates on each candidate's evidence; it currently copies ambiguity flags from the first deterministic draft into every model candidate.
- Validate model output locally. Bound output size, detect truncation/incomplete analysis, and keep screenshot text as untrusted source material.
- Extend the offline parser conservatively by recognizing supported row/block shapes. If table association is unreliable, explain that limitation instead of inventing a complete batch.

## Calendar reliability and history

Before approval, look for likely duplicates within the batch and in the chosen calendar using normalized title, date/time, and destination. Show possible calendar duplicates for user review; similarity is not enough to silently modify an existing event. Recheck immediately before execution to account for intervening changes.

Save serially and persist each successful receipt. Successful items cannot be retried as new creations. Existing process-local draft-ID protection remains useful, but durable receipts and reconciliation against calendar contents are needed across restarts and uncertain write outcomes. EventKit and local JSON do not share a transaction, so recovery must handle an event saved before its receipt was written.

Evolve capture history to an array of proposals and receipts with a schema version and backward-compatible decoding of the existing single `event` field. Opening a capture restores the batch, edits, skipped items, and save results. Library UI shows counts and per-item results. Calendar receipts and history deletion remain independent.

## Delivery sequence

### 1. Multi-event foundation

Introduce batch/proposal types and a coordinator; preserve all analyzer candidates; normalize and validate each draft independently. Migrate MemoryStore and its library consumers. Keep the one-event case working through the same batch model.

### 2. Review and approval UI

Replace the single suggestion card with the summary, selectable list, reusable event editor, source inspector, group settings, and persistent approval footer. Add explicit assumption confirmation and distinct cancel/skip behavior. Implement adaptive layout and keyboard access.

### 3. Reliable batch execution

Add duplicate lookup, approval snapshots, serial execution, per-item progress, durable receipts, stop-remaining behavior, and selective retry. Handle permission denial, missing calendars, stale analysis results, and cancellation races.

### 4. Syllabus extraction quality

Add OCR layout/evidence mapping, syllabus-specific structured extraction, course/year context, deadline semantics, and conservative multi-row offline parsing. Use representative screenshot fixtures to improve association accuracy.

### 5. Polish and follow-up

Verify the capture-to-calendar experience with real permissions and a test calendar. Then add “Add another screenshot” to accumulate a longer syllabus, deduplicate overlapping captures, and preserve evidence per capture. Existing-event edits/deletes and other action types get their own review and execution rules later.

## Acceptance checks

- A fixture containing eight assignment deadlines and two exams yields ten distinct proposals with the correct title/date associations and no invented times.
- Mixed semester years, missing years, ambiguous dates, date-only deadlines, timezone differences, and “TBD” are handled visibly.
- A single-event screenshot still works; a screenshot with no calendar items gives a useful empty state.
- Users can edit one item, apply a group setting, skip/reselect items, and approve only the intended selection. Invalid items never reach the writer.
- Cancelling analysis or starting another capture cannot publish stale candidates. Cancelling review performs zero writes.
- Double-clicking approval, retrying failed items, and reopening a saved batch do not create duplicate successful events.
- A partial failure keeps successes and failures separate. Stop leaves an accurate record of completed and pending items.
- A restart between a calendar write and receipt persistence is reconciled before retry.
- Old capture history loads after migration; edited batches and receipts survive restart.
- Review controls stay usable at supported window sizes and through keyboard/VoiceOver. Calendar dates are verified in a dedicated test calendar, including all-day and daylight-saving boundaries.

Use fixture tests for extraction, validation, migration, and recovery; use a fake calendar service for approval/cancellation/partial-failure behavior; use manual native UI and EventKit checks for permissions and the actual write flow.
