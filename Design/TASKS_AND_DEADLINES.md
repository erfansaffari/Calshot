# Tasks and deadlines

Status: first implementation. The owner approved a separate Tasks page, connected-calendar deadlines for dated tasks, and tasks/deadlines before smart planning. Calendar presentation is preserved. The earlier `Task-calendar-concept.html` is an exploratory prototype, not the shipped layout.

## Implemented flow

Tasks has its own sidebar item and page. Users can add a title-only task, edit details, complete/reopen, drag or use visible arrow buttons to reorder, archive and restore. Views include All tasks, Today & overdue, Upcoming, Inbox, Completed and Archived. Manual order is stored independently of date sorting. Reordering never changes deadlines. Native snapshots own persisted data; React keeps unsaved form inputs and presentation state only. Errors remain by the form, affected task, or sync controls.

A task may have a date, optional exact due time, timezone, notes, source evidence and an explicit Mac notification. Date-only tasks never gain an invented 11:59 PM time. Strict native date validation rejects impossible dates and nonexistent daylight-saving times.

Every dated task prepares a linked deadline for a selected writable connected calendar. It is an all-day, one-day entry above the timetable, marked free/transparent through EventKit, Google, Outlook or iCloud. An exact due time remains in its title, notes and task fields. It does not reserve a work session. Calendar creation, updates and explicit removal use existing native review, duplicate checks, approval tokens, current task versions and receipts. Task storage success never implies calendar success. Cancelled and failed publication remains visible and retryable. Linked updates first read their original event; an unavailable original never triggers an automatic replacement. Edits to a linked deadline are managed on its source Mac. Other Macs can complete or reorder the task.

Completing or archiving cancels a task’s pending Calshot notification and retains its historical provider deadline. Clearing a previously published date prepares an unchecked calendar deletion requiring explicit selection and approval. No hard-delete action is offered; archived tasks remain recoverable.

The agent has `list_tasks` and `create_tasks`. Requested assignments, to-dos and actionable deadlines use task storage; actual meetings, classes, scheduled exams and shifts remain calendar events. Imported tasks and dated deadlines share one explicit native approval; Skip saves neither. Inbox rows can be selected individually. Task-import receipts distinguish persisted task records from calendar receipts. Undated or unresolved-year tasks remain in Inbox with source evidence. Dated items use the same batch calendar review inside the existing conversation/notch. Repeated identical imports return existing task IDs rather than duplicating them. There are no agent task-update or planning tools yet.

## Reminders

Mac reminders are explicit local notifications, independent of calendar time. Choices are None, At deadline, 1 hour before and 1 day before. A date-only task needs a visible chosen reminder time; it remains separate from the task’s due time. Swift owns notification permission, scheduling and cancellation. Versioned notification identifiers and session checks reject stale scheduling work. Completion, archive and sign-out clear pending reminders; new-account loads clear previous-account notifications. Permission denial or scheduling failure appears on Tasks. The UI promises scheduling, not guaranteed delivery; macOS controls delivery and notification settings. The web does not deliver reminders.

## Persistence and sync

`CalshotTasks.swift` stores `tasks-v1.json` atomically with restrictive file permissions inside the existing account-specific history directory. A corrupt file stays untouched and blocks mutation. Matching receipts in this Mac’s history repair a missed task receipt after interruption; recovery never replays writes. A failed account load clears the visible task document rather than exposing the previous account’s tasks.

The private web repository owns migration `20261022163253_personal_tasks_and_deadlines.sql`, `public.task_state`, owner RLS and scoped invoker RPCs backed by private authenticated functions. Read/write calls derive identity from Supabase, require verified accounts and validate bounded task documents. Revisions reject stale cloud writes. Per-task version baselines merge independent edits; conflicts require explicit Keep both. A retained local copy has a new ID and no calendar receipt or enabled reminder. Sync never executes calendar proposals or replays history.

The authenticated website imports the same Tasks presentation read-only, with an explicit Mac handoff for editing and calendar approval. Client credentials and native write logic stay in their existing owners.

## Verification and scope

Native tests cover strict dates/DST, account storage and corrupt-file isolation, stale actions, WebKit numeric/boolean types, approval ownership/version checks, explicit calendar approval, ordering/completion/archive, unresolved-year imports and sync conflicts. React interaction tests cover title-only creation, captured edit tokens and preserved input, reorder payloads, persistent errors, archived tasks and the read-only web view. Database checks use fictional users inside rollback transactions, including hosted RLS and revision-conflict verification. The hosted migration source checksum matches the private migration file.

Inspect compact and expanded native/browser layouts with isolated fixtures (`--tasks-preview` and `?preview=1&scenario=tasks`). No real calendar writes are needed. OS notification delivery and live model extraction remain separate integration checks.

## Deferred

Smart planning, effort estimates, work-hour preferences, linked work sessions, custom alarms, task sharing, web mutations, task details opened from calendar chips and a redesigned all-day band are deferred. Calendar currently uses its existing separate bounded all-day row; this feature adds no task overlay or side panel. Planning must eventually read fresh calendar coverage and propose work sessions for approval, while excluding free deadline entries from busy time.
