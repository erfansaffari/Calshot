# Calendar agent prompt: fewer unnecessary questions

Runtime source: `Core/CalendarAgent.swift`, `instructions` and the tool descriptions. The same policy reaches screenshot tasks, typed requests and clarification continuations on both configured AI billing routes. Prompt changes preserve native approval and calendar validation. The Tasks feature adds explicit task-import tools; see TASKS_AND_DEADLINES.md.

Decision order: understand the requested outcome → reuse clear context → read missing calendar facts → prepare useful review rows → ask only for an unresolved blocking choice. The saved writable destination is the default; absent optional fields do not require questions.

## Behavior scenarios for model evaluation

These are evaluation expectations, not claims of passing live-model tests. Use fictional calendars and a fixed clock of 2026-10-22 10:00 America/Toronto in an isolated executor. Record the actual tool trace, question count, review rows and final outcome; never perform real calendar writes.

| Request and fixture | Expected behavior | Failure to look for |
| --- | --- | --- |
| “What do I have tomorrow?” | Search October 23 local midnight through October 24 local midnight; answer from returned events. | Asking permission to search, asking for the year, proposing writes. |
| “Add this workshop to my calendar.” Source explicitly gives November 10, 2026, 14:00–15:00; default destination is Personal. | Prepare one create review using the app destination. | Asking which of several connected calendars to use, or asking “Should I add it?” |
| “Add all exams.” Screenshot is headed Fall 2026; three exam rows, one time TBD. | One review with three rows; keep the incomplete row unresolved. | Three time questions before review, inventing an end time, dropping the TBD row. |
| “Add these deadlines to Work.” Only one returned writable calendar is named Work. | Resolve its ID from search calendar metadata and prepare review there. | Asking to choose Work again or guessing a calendar ID. |
| Same request, with two writable Work calendars under different accounts. | One question distinguishing account/source; retain the answer when preparing review. | Asking which calendar again after the answer. |
| “Move the dentist appointment on November 10, 2026 to 15:00.” | Targeted search first; update only requested fields, then native review. Respect any target clarification required by validation. | Broad unrelated searches creating needless ambiguity, clearing location/notes, writing without review. |
| “Move these two weekend shifts from Personal to Work.” Search identifies both and the destination. | One move review with both source → destination rows. | Separate create/delete approvals or treating a clearly requested group as an either/or choice. |
| “Add the project deadline, November 10.” No governing year or all-day confirmation. | Stage an Inbox task with unresolved-year evidence and no calendar write; do not guess from the current year. | Guessing 2026 or claiming the calendar was updated before approval. |
| “Is Riley free tomorrow?” Shared search is stale or partly failed. | Recheck current grants and shared data, explain the coverage gap. | Claiming availability, inferring hidden titles, or offering unsolicited copies. |
| A review saves two rows, fails one, and skips one. User asks to retry the failure. | Retry only the failed row through review; report receipts. | Recreating saved rows or reconsidering the skipped row. |

## Verification boundaries

Native scripted tests verify that policy, original request and clarification answers remain present across tool turns. Existing native tests cover ambiguous-target rejection, unresolved fields, receipt handling and cancellation. They do not measure whether a live model follows these instructions. Compare live traces for the scenarios above before claiming fewer questions quantitatively.

Native `update_event` and `delete_event` validation can require target clarification after a search returned multiple matches. The prompt asks for targeted initial searches and respects that guard; it does not bypass it. Creates/transfers support batches; updates/deletes still operate on individual searched events. Screenshot imports see only the supplied visible area.
