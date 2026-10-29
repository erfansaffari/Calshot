# Calshot — UI/UX designer handoff

Prepared October 14, 2026. This brief describes the product, the owner's expectations, existing capabilities, and the experience to design. Examples use fictional people and calendar data.

## 1. What we are building

Calshot is a macOS calendar agent. A user captures a screenshot of a syllabus, timetable, assignment list, shift roster, or event announcement, or types a request. The agent understands the request, checks connected calendars, asks about anything unclear, and presents calendar changes for approval. It performs only the approved changes and reports what actually happened.

The product promise is: **Turn what you see or ask into calendar changes you can understand, edit, and approve.**

The app should support an ongoing conversation, rather than feel like a form that extracts one event from one screenshot. It should remember relevant previous actions and answers, work across the user's calendars, and make the next step clear.

Primary users include students importing course deadlines and exams, workers importing shifts, and people coordinating personal, school, and work schedules across multiple accounts.

## 2. What the owner wants from this redesign

The current interface feels scattered and difficult to understand. Account connections are unclear, chat responses and approvals have appeared in different sections, and calendar transfers have required repeated destination selection and separate confirmations. A long clarification question also caused an interface freeze. These are core problems for the redesign to address.

The desired experience is polished, calm, responsive, and easy to change. The user should always understand what the agent is doing, what it needs from them, which calendars are involved, and whether a change has actually finished. A screenshot with twelve assignments should lead to one understandable batch. A request to move two events should lead to one transfer review.

The owner prefers React for the future main interface because they want more freedom to achieve this visual experience. The proposed architecture is a React interface inside the native macOS app, with the existing Swift services underneath. The current main interface is still SwiftUI; the migration is paused so the design can guide it. Framework choice alone does not determine the design quality.

## 3. Platform and design scope

Design a desktop macOS application with a resizable window, standard window controls, keyboard interaction, and a menu bar entry for quick capture. Screenshot capture, permissions, calendar access, account authorization, and secure credential storage remain native responsibilities.

The current default window is approximately 1050 × 720, with a minimum of 920 × 650. Please explore a comfortable primary layout around 1120 × 780, a compact layout at 920 × 650, and an expanded layout around 1440 pixels wide. These are desktop layouts, not mobile screens stretched into a window.

The screenshot contains the selected visible area. Calshot does not currently scroll through a whole webpage automatically. The design must not imply that content outside the captured area has been read. A future flow for adding another screenshot to the same task can be explored, but label it as proposed functionality.

## 4. Suggested information architecture

The current sections are Capture, Chat, Calendars, Memory, and Settings. The designer may improve their naming and grouping. The following responsibilities need a clear home:

| Area | User's purpose | Key content |
| --- | --- | --- |
| Assistant / Chat | Ask, capture, review, and finish a task | Conversation, screenshot context, questions, approval cards, results, composer, Stop |
| Capture / Source | Inspect what the agent is working from | Screenshot preview, OCR text when useful, source evidence and unresolved details |
| Calendars & Accounts | Understand and manage calendar access | Connected accounts, calendars, permissions, read-only status, destination preference, reconnect |
| Memory / History | Find and continue earlier work | Previous captures and conversations, action outcomes, screenshot thumbnails, resume |
| Settings | Configure the app | AI provider, permissions, storage, privacy, capture preferences, advanced connection setup |

The most important proposal is to bring questions, approvals, and results into the conversation. The user should not need to leave Chat to approve a task that started there. Source inspection can be a contextual panel, expandable attachment, or another well-integrated treatment.

## 5. Core interaction model

A screenshot or typed command starts an agent session. The agent can inspect the image, read recognized text, search calendars, ask a question, or propose changes. Read operations do not need approval. Calendar writes wait for the user to review them.

The interface needs three clearly distinguishable layers: what the user requested, what the agent proposes, and what the calendar service confirms happened. A proposal is not a completed action. A model message cannot serve as proof that an event was saved.

The agent currently has a limit of eight model turns per run. If it reaches the limit, show “The agent reached its step limit.” Keep the results of earlier approved writes visible. The user should be able to continue intentionally without accidentally repeating completed writes.

Starting a new capture cancels the old active session. Stop ends the current loop. Events already written remain written; pending actions are skipped. Late results from an older session must not replace the current interface.

### Flow A: Import a syllabus

The user captures a syllabus showing twelve assignments, tests, and deadlines. Calshot displays the screenshot as context and gives understandable progress feedback. It identifies the visible events and checks calendars for possible duplicates.

If the syllabus lacks a year, uses “TBD,” or leaves a time unclear, the agent asks rather than inventing a value. A date-only deadline becomes all-day only after the user confirms that interpretation. Several related uncertainties should be resolved efficiently where possible.

The user receives one batch with all twelve proposals. They can inspect evidence, fix dates or titles, choose the destination, select ready items, and exclude others. Unresolved rows explain what is missing and cannot be approved prematurely.

After approval, show actual per-event outcomes. If nine save and three fail, display that result clearly and offer a retry for those three. The successful nine must not be added again. The final summary distinguishes added, skipped, failed, and unresolved items.

### Flow B: Ask about the calendar

The user asks, “What do I have tomorrow?” Calshot searches the relevant connected calendars and replies with a readable agenda, including dates, times, and calendar names.

There is a critical difference between “No events found” and “One calendar could not be read.” Show the searched date range and source coverage where useful. Never present an incomplete search as a definitive empty schedule.

### Flow C: Move two events between calendars

The user asks, “Move my two weekend shifts from Personal to Work.” Calshot searches for the source events and resolves the destination. If the request identifies them clearly, do not ask the user to choose the same destination again.

Present one transfer review with both events, their dates and times, and **Personal → Work**. Explain in plain language that the destination copy is verified before the original is removed. One approval authorizes the reviewed transfer of selected rows; it should not become a create approval followed by a separate delete approval.

If an earlier attempt already created a matching destination copy, reuse it when verified instead of creating another. If copying fails, preserve the original. If copying succeeds but original removal fails, say so explicitly: “Copied to Work; original still in Personal.” An interrupted transfer must remain understandable and recoverable.

### Flow D: Change or remove an event

For “Move Thursday's class to Friday,” search first. If several events could match, ask which one before proposing an update. Show current and proposed values together, emphasizing changed fields.

For deletion, show the exact event, calendar, date, and time. Delete rows start unchecked and require deliberate selection. Cancelling or skipping leaves the event untouched. Current recurring-event changes apply to the individual occurrence; whole-series editing is outside this release.

### Flow E: Connect a calendar account

The user opens Calendars & Accounts and can immediately tell what is usable. Existing calendars available through macOS should be discovered and reused. Direct account connections should not create a second visible copy of the same calendar.

Connecting Google or Outlook involves browser authorization and returning to Calshot. The app must distinguish successful sign-in from successful calendar access. Permission denial, organization restrictions, expired access, read-only calendars, and unavailable provider setup each need a specific explanation and next action.

Technical OAuth registration fields belong in advanced setup, not the ordinary user connection flow. Never display secrets in mockups or the finished interface.

### Flow F: Resume from history

The user finds a previous capture or conversation, sees what was requested and what happened, and continues with a new instruction. Resuming must not automatically replay earlier writes. Previous skipped and cancelled actions should not quietly return as approved work.

## 6. Main screens and components

### Assistant workspace

Create a readable conversation timeline with distinct user messages, assistant replies, screenshot attachments, clarification cards, approval cards, and completed results. Long replies and long tasks must scroll predictably without hiding the current action.

The composer supports typed commands and the current screenshot as context. Example prompts include “Make these deadlines all-day,” “Delete the old midterm and add this date,” and “Move Thursday's class to Friday.” Show what screenshot is attached and allow the user to understand or change that context.

Streaming replies should remain visible. Progress labels should describe meaningful activity, such as “Reading the screenshot,” “Searching School,” “Waiting for your answer,” “Waiting for approval,” or “Moving 2 events.” Keep raw tool names, JSON, and network diagnostics out of the main flow.

Stop must be easy to find during a run. When input is unavailable, explain why and provide the appropriate answer or approval control. Avoid a disabled-looking chat with no apparent next step.

### Clarification card

Show the question in full. Support up to six choices, a free-text response when appropriate, and Cancel. Choices may contain long event titles, dates, and calendar names; they need wrapping, accessible focus, and bounded scrolling without unstable layout or clipped buttons.

Cancelling returns a cancellation to the agent. It is not approval and must not trigger the associated change. Keep the chosen answer visible in the conversation after submission.

### Batch review and action rows

Preserve the capabilities of the existing batch review, while improving its presentation and placing it in the task context. Each row needs an operation, selection state, event title, date/time, calendar, validation state, and access to details. Use labels as well as color.

The review supports Add, Change, Remove, and Move. Creates and updates can start selected when ready. Deletes start unselected. A transfer shows source and destination explicitly. A mixed batch footer might read “Add 9 · Change 1 · Remove 1,” with the approval button counting only selected, approvable actions.

Provide efficient editing for title, date, start/end time, all-day, time zone, location, URL, and notes. Evidence from the screenshot should be easy to inspect without overwhelming every row. Consider safe batch corrections, such as setting a confirmed year or confirming all-day deadlines, as interaction proposals to coordinate with engineering.

Unresolved items explain the required correction. Possible duplicates show the matching existing event and require deliberate resolution. Completed rows should remain visible as results but should not steal focus from the next pending review.

For updates, show before and after. For deletes, show what will be removed. For moves, show the reviewed source and destination, including whether a destination copy already exists. Approval and skip controls need an unambiguous scope: this row, selected rows, or this pending batch.

### Results and receipts

After a write, use explicit labels: Added, Updated, Deleted, Moved, Failed, Skipped, or Needs review. Show a concise overall result with per-row detail available. An error should identify the affected event and useful next action.

Support partial outcomes, retrying failed rows, interrupted-write recovery, and transfers whose copy succeeded but source removal did not. Never replace these with a generic “Done.”

### Calendars & Accounts

Use a clear hierarchy of account → calendars. Show provider, human-readable account identity, connection state, access level, and calendars available. Make the default destination for new events understandable, while allowing task-specific destinations.

Design states for connected and usable, connecting, signed in but calendar access unavailable, reconnect required, permission denied, read-only, provider unavailable, and setup pending. Explain macOS-provided versus direct access when it matters, using simple language and expandable detail.

Calendar deduplication should be reflected in the interface: one logical calendar should not appear twice merely because it is available through two access routes. Do not imply a calendar is disconnected simply because one route fails while another still works.

### Memory / History

History entries should communicate the task, date, screenshot thumbnail if present, and outcome. Users can inspect the source, review the conversation and write results, and resume deliberately. Include an empty state, loading state, and unavailable-image state.

Deleting a history record must clearly describe whether it removes local task data. It must not imply that calendar events are also deleted. Calendar changes require their own explicit action review.

### Settings and permissions

Separate ordinary preferences from advanced developer setup. Calendar permission and Screen Recording permission need clear status and actionable recovery. Show permission requests when the corresponding feature is needed.

AI settings must distinguish a connected ChatGPT plan from an OpenAI API key. API usage is billed separately. The selected route is a saved user choice; switching to the paid API route must be explicit. Show credential presence and connection health without revealing credentials.

## 7. State coverage required in the design

| State | What the user needs to understand or do |
| --- | --- |
| First launch / empty | Understand the value, capture something, type a request, or connect a calendar |
| Missing permission | Know which feature is blocked and how to enable access |
| Capturing / reading | See the source and know processing has started |
| Searching / streaming | See useful progress and access Stop |
| Waiting for an answer | Answer, choose, or cancel within the conversation |
| Waiting for approval | Inspect exact changes and approve or skip the selected scope |
| Missing details | Identify and resolve year, time, date, time-zone, or URL issues |
| Possible duplicate | Compare the existing event before deciding |
| Saving | Understand that approved work is in progress without double-submitting |
| Partial failure | See successes and failures separately and retry only the failures |
| Stopped | See what finished and what was skipped |
| Step limit | See the limit message and retained results, with an intentional continuation path |
| Provider / network failure | Understand the impact and useful retry or connection action |
| Incomplete calendar search | Know which calendars were searched and which were unavailable |
| On-device fallback | Know extraction was used and proposals still need review |
| Interrupted recovery | See the reconciled state without accidentally repeating writes |
| Complete | Read an accurate summary and continue with a follow-up |

## 8. Existing capability versus planned availability

The following is implementation context as of this handoff. A provider being implemented does not mean every live connection has been verified.

| Capability | Current position |
| --- | --- |
| Main desktop UI | Native SwiftUI/AppKit; React main-interface migration proposed and paused for design |
| Screenshot capture and OCR | Implemented; visible-region capture, with OCR and on-device extraction fallback |
| Calendar agent | Implemented tool loop with search, screen text, questions, create, update, delete, and move tools |
| Approval and receipts | Implemented batch review, selected writes, durable journaling, and recovery paths |
| Apple/macOS calendars | Implemented through EventKit, including accounts already configured in macOS |
| Google direct connection | OAuth and calendar access verified in prior testing; matching native/direct calendars can be linked |
| Outlook / Microsoft 365 | Adapter implemented; app registration remains pending because the available organization account cannot register apps; direct live access is not verified |
| Direct iCloud | Adapter implemented; live app-specific-password verification remains pending |
| Notion Calendar | Intended coverage is through its underlying supported calendar accounts; no separate Notion Calendar event-store integration is implemented |
| Memory | Local captures, OCR, transcripts, proposals, and write outcomes are persisted; relevant bounded history can inform later calls |
| OpenAI API key route | Working in prior end-to-end testing and explicitly selected as the current route |
| ChatGPT plan route | Sign-in retained, but the model endpoint has returned an upstream HTTP 520; treat this as a recoverable provider issue |

Notion Calendar is distinct from dates in Notion database pages. Database sync is not part of this product scope. Do not present a “Connect Notion” button as a working independent calendar connection without a supported implementation.

## 9. Trust, privacy, and safety requirements

The user approves calendar writes. Read access, proposed changes, approved changes, and completed changes must be visibly distinct. Missing years, missing times, ambiguous dates, and “TBD” remain unresolved until clarified. Do not infer all-day intent solely from a missing time.

Search should precede changes and deletions. Ambiguous event matches require clarification. Read-only calendars can be useful search sources but cannot be offered as writable destinations.

Calshot stores local history, including screenshots, recognized text, conversations, and action receipts. Screenshots are separate image files. Cloud analysis can send the captured image, user instructions, requested text, relevant calendar results, and bounded historical context to the chosen AI service. Requests use the API's store:false setting; do not turn that into a broader claim that no provider processing or retention ever occurs.

Credentials belong in macOS Keychain and must not appear in chat, history, screenshots of settings, or model context. The app captures when the user requests it; the design must not suggest continuous screen surveillance.

## 10. Visual direction and accessibility

Aim for a focused desktop productivity tool: strong typography, calm hierarchy, consistent spacing, restrained color, and clear primary actions. Make complex calendar work feel manageable. Avoid turning every tool step into a large card, exposing development diagnostics by default, or relying on decorative animation to communicate progress.

The designer should propose the visual language, including typography, spacing, color, iconography, surfaces, and light/dark treatment. The current app uses a dark appearance, but this does not prescribe the final palette.

Support keyboard navigation, visible focus, meaningful accessibility labels, adequate contrast, reduced motion, and status communication beyond color. Long calendar names, long questions, twelve-event batches, and many accounts must fit gracefully. Critical actions cannot depend only on hover. Confirmation controls must remain reachable at compact window sizes.

## 11. Scope boundaries

This release focuses on user-directed calendar work from screenshots and conversation, with explicit review. Whole repeating-series editing, automatic scrolling, full webpage ingestion, window capture, Notion database sync, mobile/web versions, and unattended background writes remain outside scope. Outlook registration and unverified provider routes must be represented honestly rather than shown as universally available.

## 12. Requested design deliverables

Please deliver an information architecture and user flows, low-fidelity layouts for the main workspace, and high-fidelity designs for the core screens and important states above. Include a reusable component system with typography, spacing, color, icon, interaction, and status tokens that can be implemented in React inside the native app.

Create interactive prototypes for a twelve-event syllabus import with ambiguity and partial failure; a two-event calendar transfer with one approval; and account connection with an unavailable or restricted provider. Include compact and expanded desktop layouts, keyboard/focus behavior, long-content behavior, loading/error states, and annotations explaining what each control does.

Use fictional accounts and schedules in shared design files. Label proposed features separately from implemented behavior. Engineering should be able to map components to agent progress, pending questions, approval batches, account state, and actual write receipts.

## 13. How we will judge the design

A first-time user should quickly understand which calendars are usable, what screenshot or request the agent is processing, and what they need to do next. Before approval, they should be able to identify exactly which events and calendars will change. After execution, they should be able to distinguish success, failure, and pending work without interpreting technical messages.

A student should be able to review a full syllabus batch efficiently. A calendar transfer should require one coherent review with the destination already filled when known. A clarification question should remain responsive even with long choices. A user should be able to stop, recover, or resume without duplicate events or uncertainty about what has already happened.

The design succeeds when Calshot feels like one understandable conversation with a capable calendar assistant, supported by clear sources, precise approvals, and trustworthy results.
