# Calshot agent platform plan

Status: implementation underway. Originally prepared 2026-10-23 from the owner's requirements and three GPT-6.1-Sol medium research assignments; implementation was subsequently authorized. Task linking, calendar intent and device-local task permissions are implemented. Durable sessions/memory, the cloud coordinator and proactivity remain planned. The earlier UI work was pushed as `9011dc9`.

## 1. Intended product

One assistant should understand the user's request, preserve context within each conversation, know the status of other work when relevant, remember inspectable preferences, and act quickly within permissions the user has deliberately granted.

The central coordinator is primarily application code, not an additional model call before every action. Each independent conversation/goal has its own durable session. One conversation can concern multiple tasks, and one task can be referenced in multiple conversations. Specialist agents are used only for substantial independent work. Simple actions use one session or a deterministic native command.

The first delivery must solve the concrete failure: selecting an existing calendar event and asking to add it to Tasks creates or returns a linked task, with zero calendar writes. Detecting a duplicate without a valid linking operation is not an acceptable outcome.

Owner priorities:

- Fast, useful responses and minimal repeated questions or confirmations.
- Tasks-only creation, linking existing events, and publishing new deadlines are distinct operations.
- Settings can authorize routine requested actions without per-action review. Background permissions are separate.
- Persistent, editable/forgettable memory and separate task/chat contexts.
- Useful opt-in proactivity and eventual other-OS support.
- Preserve source identity, accurate receipts, account isolation, cancellation and interrupted-write recovery.
- Preserve the user's AI billing choice; no silent cloud credential transfer or API fallback.

## 2. Current implementation and constraints

`Sources/Agent/CalendarAgent.swift` runs up to eight model rounds and executes tools serially. `Sources/Agent/ResponsesCalendarAgentClient.swift` streams stateless Responses requests with `parallel_tool_calls:false`. `CalendarAgentToolExecutor` searches sources serially and exposes at most 40 merged results. Its questions and approvals wait on in-memory continuations. Current task memory is bounded history, not an editable knowledge store.

The task problem spans `Sources/Tasks/CalshotTasks.swift`: dated imports generate calendar proposals, import commit requires selected dated proposals, publication is inferred from date/receipt, and task publication receipts choose create/update/delete. A source event must never be inserted into that publication receipt field.

Task mutations are currently guarded by the Tasks page and idle-agent checks. Conversation/notch mutations need a shared domain command service, rather than bypassing those checks or calling page-only bridge methods.

Selected Calendar events currently become natural-language request text; their trusted native identity is not passed through. Calendar snapshots also need reliable original recurrence identity and revision information before durable links can be guaranteed.

React owns presentation. Swift owns local permissions, credentials, capture, adapters, task/calendar validation and writes. The private `CalshotWeb` repository owns hosted backend, migrations and website source. Its strict task JSON validation requires a coordinated additive migration before clients sync new fields.

## 3. Domain contracts before framework migration

### Tasks and calendar intent

Persist a resolved calendar intent per task together with `intentProvenance: defaulted | explicit | suppressed` and the resolved publication preference used for defaults:

| Intent | Meaning | Provider writes |
| --- | --- | --- |
| `none` | Task only, dated or undated | None |
| `existing` | Task with an exact source-event link | None |
| `new` | Task with a Calshot-published deadline | Validated create/update/removal as applicable |

Ordinary dated task creation uses the resolved publication preference, initially `new`. Undated creation is `none/defaulted`; adding a date applies that preference only to a defaulted choice. An explicit Tasks-only request is `none/explicit` and stays `none` when dated later. “Add this event to Tasks” is `existing/explicit`. Suppressed copies never automatically publish, including when dated later; enabling publication requires an explicit operation. Preserve intent, provenance and preference across editing, sync and restore.

Legacy migration is decoding/state migration only and MUST dispatch zero provider writes. Precedence: a valid owned publication receipt resolves to `new` with its existing receipt/recovery state; otherwise a dated unpublished legacy task resolves to `new/defaulted`, preserving its pending/unpublished state without scheduling it; otherwise an undated legacy task resolves to `none/defaulted`. Conflict-copy suppression overrides these defaults: every conflict copy, dated or undated, is explicitly suppressed, with no active publication ownership. A source-linked conflict copy may retain provenance but MUST NOT become a second link-registry owner. A retained receipt needed for recovery is evidence, not authority to publish the copy.

New safety fields MUST survive older whole-document clients. Before enabling new clients, deploy a versioned task write RPC/schema gate that accepts only supported protocol versions and preserves safety fields server-side or rejects writes that could remove them. Missing/old versions cannot replace protected records. Old installed apps must retain local edits and cannot overwrite new intent/link/suppression fields. The RPC must return an update-required compatibility error through the existing persistent sync-error path; verify that installed clients render it clearly before rollout, and block rollout if they cannot. Updated clients present “Update needed to sync tasks” where applicable; reads must also fail clearly if safe decoding is impossible. Backend-first rollout and old-client fixtures are release gates, not assumed private-backend capabilities.

Separate three records:

1. **Source link:** canonical provider/account/calendar/event/occurrence (or explicitly device-scoped identity), local connection handle separately, originating device, observed version/fingerprint, observation time, allowed provenance and availability status.
2. **Publication:** receipt for a deadline Calshot created, execution device and last published task fingerprint. Only an active `new` publication uses maintenance; retained artifacts have separate provenance and are excluded from future task-driven maintenance.
3. **Task-operation receipt:** operation ID, task ID/version and saved/already-linked/failed outcome; include a separate calendar result only when one was requested.

Linking does not annotate, change or delete the original event. Completing, archiving, renaming or rescheduling an `existing` task affects the task only. Source refresh updates observations and status; applying changed source dates/details is a separate explicit task mutation. Missing source access never creates a replacement. Detaching preserves the task.

For `new`, preserve current semantics: completion/archive retains the provider deadline, and removal of a published date is a calendar deletion subject to applicable authorization. Detect external changes before a task-driven provider update. A `new` → `none`/`existing` transition MUST explicitly choose retain or remove the owned deadline; do not infer either from the intent edit. Removal requires authorization for that exact artifact. Preserve the old receipt and recovery state until the transition settles, including cancellation, failed removal and uncertain outcomes. Retain records the artifact as retained/inactive with its receipt, distinct from active publication; future task changes do not update or remove it. Transitioning to `existing` also requires independently validated source identity.

### Exact selected context and idempotency

Calendar detail controls send a native-resolved event handle plus current view generation. Native code creates an opaque selected-context token bound to owner, source, occurrence, session and observation. Model-supplied labels/IDs and screenshot content cannot confer authority.

`link_event_to_task` validates that token, rechecks readable access and source state, then creates or returns a task. First-delivery default: device-scoped durable identity and local atomic create-or-return on owner + device + verified source/occurrence. Repeated clicks, retries and later conversations on that device return the same task; an archived match is reported and can be explicitly restored. Device-only/offline links do not promise cross-device uniqueness. Task-document CAS merging independently generated task UUIDs (`Sources/Tasks/CalshotTasks.swift:252`) cannot supply that promise.

Cross-device canonical provider links require an owner-scoped atomic registry/upsert with a unique key of owner + provider + canonical source subject/account + calendar + stable event occurrence, returning the canonical task ID. The source subject MUST survive reconnect and MUST NOT be a local connection UUID or email label. Registry ownership and task creation/reference must commit atomically or have a recoverable reservation that cannot admit a second owner. Ship this guarantee only after backend availability, owner isolation, reconnect identity and concurrent-upsert acceptance tests pass. Until then use visibly device-scoped links.

Offline provider-backed records are provisional and device-scoped. On reconnect, reconcile through the registry before claiming canonical ownership; concurrent provisional tasks resolve to one canonical owner and preserve other tasks as suppressed provenance copies/references with an inspectable resolution. Reconciliation MUST NOT publish, delete or modify calendar events, silently discard task edits, or create another registry owner. Registry outage retains provisional status and a retryable sync state; no cross-device guarantee while unavailable.

Provider adapters MUST distinguish stable event identity from observed mutable dates and expose original recurrence anchors. Normalize original all-day anchors as date-only values with calendar timezone semantics; timed anchors use a documented normalized instant/timezone representation. Scope provider IDs by provider, canonical account and calendar; never identify by title, calendar name or mutable start/end. A moved occurrence retains its original anchor; the next occurrence is distinct. Current `Sources/Agent/CalendarAgentToolExecutor.swift:365` uses UID plus mutable start/end and is not this contract.

Display/transport calendar aliases and verified canonical event/occurrence mappings are separate records. `Sources/Agent/CalshotModel+CalendarAgent.swift:291` only selects/hides duplicate calendar transports; it proves no event mapping. Alias changes, reconnects and route switches MUST NOT merge links or mint a replacement identity unless an adapter verifies source and occurrence equivalence. Unverified EventKit references remain device-scoped; a display alias never promotes them. If identity cannot be established, offer an explicit independent suppressed task copy rather than claiming a durable canonical link. Adapter identity and route-switch fixtures are phase 1 gates.

Readable source resolution MUST be separate from writable destination validation. In `Sources/Calendar/EventKitCalendarService.swift:105`, `event(identifier:in:)` currently calls `writableCalendar`; the planned readable lookup must validate access and exact calendar membership without requiring write permission. Update/delete retain writable-target validation. Personal read-only source selection must resolve/link with zero provider writes, while attempted mutation of that same source is denied.

All-day links preserve the source calendar date/timezone without inventing a due time. Multi-day sources retain their range and ask for a task deadline only when that choice is necessary. Personal read-only sources may supply provenance without calendar write access. Friend-source links require permission-aware storage/redaction; they never grant provider write access.

### Shared commands and tools

Create one caller-independent native task command service used by UI, conversation, notch and eventual coordinator. Trusted callers supply owner/store/session/origin information; the model supplies only validated operation arguments.

Domain operations: create, patch, link existing event, complete/reopen, archive/restore, reorder, set calendar intent, refresh/detach source. Model tools expose only available capabilities, initially `list_tasks`, `get_tasks`, `create_tasks`, `link_event_to_task`, `update_tasks`, `set_task_completion`, `set_task_archived`, and ordering/publication operations when implemented.

Patches preserve omitted fields; explicit null clears supported optional fields. Validate expected object versions and order versions. The runtime assigns durable operation IDs; model tool-call IDs are associations, not authoritative idempotency keys. Return structured per-row receipts/errors, including stale target, unavailable source, question needed, review needed, denied, cancelled and interrupted.

Mixed task/event imports MUST accumulate proposals for the requested batch before presenting review; the first write tool cannot suspend preparation into separate approval fragments. Persist a stable bundle ID and stable child operation IDs, expected versions, dependencies, digests and per-child status across retries/restart. Material changes invalidate affected authorization; a new tool-call ID does not create a new operation.

Dependencies are task save → optional provider publication → receipt attachment; this is not a transaction across task storage and provider. `Sources/App/CalshotApp.swift:794` already saves imported tasks before calendar execution. A publication failure leaves the saved task with a failed/pending calendar result. Provider success followed by receipt-attachment failure leaves an uncertain attachment to reconcile by the same child ID and journal evidence, never a fresh create. Granted independent ready rows may execute; blocked rows stay pending and dependent children wait. One coherent review covers the prepared bundle's requested effects, with later material additions requiring an updated review rather than implicit approval.

## 4. Permission and execution policy

Replace blanket per-write review with an execution-layer policy decision:

`evaluate(operation, trusted origin, current resources, current grant) → allow | require review | deny`

This intentionally revises the old always-review contract; it does not simulate a click or let the model approve itself. Existing installations retain review mode until the user explicitly enables saved permissions. Direct UI commands use the same policy evaluation. Exact-object submission provides operation-scoped authorization only for the effects shown to the user; a generic button or foreground state cannot bypass review or create a broad grant. A valid exact submission or matching saved grant needs no redundant conversational approval.

Settings presents concise action families, selected sources, limits, and separate **When I ask** / **In the background** controls. “Always review changes” remains available. One-off review and saving a reusable grant are separate choices.

| Action | Requested execution with matching grant | Background default |
| --- | --- | --- |
| Task create/link/edit/complete | Execute and show receipt | Suggestions; separate grant required |
| Archive/restore | Execute within granted scope | Separate grant required |
| Calendar create/edit | Execute on named granted calendars/fields | Separate narrower grant required |
| Delete/move/bulk/series | Review unless deliberately granted | Disabled unless deliberately granted and supported |
| Guest/invitation/sharing effects | Separate permission and capability checks | Disabled by default |
| Ambiguous/changed/unsupported/out-of-bounds action | Question, review or deny with reason | Persist blocked state; no scope widening |

Grants bind owner, execution device/service, operation/fields, resource scope, origin mode, quantity and cumulative bounds, expiry and revision. The runtime records user-requested invocation; app foreground state or model claims do not establish user presence. Background jobs cannot reuse foreground grants. Authority is local to the named device or service: synced labels/preferences are descriptive and MUST NOT activate a grant on another executor. Reconnects, account changes and calendar aliases cannot widen its scope; rebind only after identity verification and explicit authorization where scope changes.

Enforce cumulative limits using atomic allowance reservations across concurrent runs and retries before dispatch. Bind reservations to durable operation/attempt identity; release only proven undispatched/failed-without-effect reservations, settle confirmed effects, and retain uncertain reservations pending reconciliation. Retrying the same operation cannot double-spend its allowance or grant a second side effect. A genuinely new side effect requires an explicit allowance decision and a new operation; exhaustion blocks the row visibly.

Before each mutation, recheck identity, policy revision, cancellation, resource versions and capability. Authorization envelopes bind the normalized operation digest and current expected versions to a review decision or saved grant. Preserve the coordinator's pre-write journal, transfer verification and per-row receipts. Direct execution performs preflight once and proceeds without an extra click when nothing changed.

Stop cancels future work and preserves completed writes. Revocation fences remaining operations. A provider timeout after dispatch is an unknown outcome to reconcile, not permission to replay or switch executors. Retry failed rows only.

Task undo uses a version-checked inverse where implemented. Calendar undo is a new validated compensating operation with a fresh source read. Do not promise generic undo for notifications to attendees, deletion, transfers or uncertain outcomes.

## 5. Durable sessions, coordinator and memory

Introduce app-owned records independent of the orchestration library:

- **TaskSession:** owner, conversation identity, linked task IDs, summary/version, visibility/provenance scope, message sequence and lifecycle.
- **Run:** session, trigger, parent/delegation, executor location, lease/fencing generation, billing/model route, capability snapshot and cancellation generation.
- **Action:** operation ID/digest, expected versions, authorization revision, executor, attempts, journal state and receipts.
- **Message/question:** immutable IDs and ordered content; questions persist their ID, choices and answered/cancelled state.
- **Memory:** owner/scope, explicit versus inferred origin, content, source references, sensitivity, confidence, version, expiry and tombstone.
- **Connection/resource:** opaque provider/account identity, device/cloud location, current capabilities/freshness and stable resource reference; never credentials in snapshots.

Runs: queued → running → waiting for question/authorization/device → running → succeeded/partial/failed/cancelled. Expired execution leases become interrupted; dispatched or uncertain actions remain fenced to reconciliation, never reassigned for execution merely because the lease expired. Waiting releases the worker rather than holding a request open.

The coordinator indexes bounded summaries of objectives, status, blockers, next steps and receipt references. It retrieves full context only when relevant and authorized. Summaries never replace authoritative task/calendar/policy state. Separate sessions must not leak selected objects, stale answers or private/shared-source content into one another.

Semantic memory sync MUST have its own explicit opt-in toggle, initially off. Account sync, history sync, cloud orchestration and OAuth consent cannot enable it. Memory-derived summaries/caches carrying semantic facts inherit the same privacy scope and sync restriction; routing through session summaries cannot bypass the toggle. Phase 3 uses local records/retrieval and requires no embeddings. Cloud orchestration must omit local-only semantic context unless separately authorized.

Start memory with explicit preferences and optional suggested memories. Provide inspect/edit/forget controls with source, scope and update/expiry information. Proposed defaults: local semantic memory until the separate semantic-memory sync toggle is explicitly enabled, no screenshot/friend-data extraction by default, inferred facts expire after 90 days unless retained. These are product defaults to validate, not existing behavior.

Forget invalidates retrieval entries, embeddings if introduced, summary caches and replicas. Versioned forget/suppression tombstones propagate within the authorized memory scope and take precedence over stale offline replicas and derived summaries before retrieval or re-derivation; reconnect cannot recreate the fact from history or re-upload stale memory. Keep sufficient suppression metadata until all eligible replicas acknowledge it or a documented safe retirement rule applies. Local-only memories and suppressions stay local while semantic-memory sync is off. Distinguish forgetting a memory from deleting its source conversation and disclose backup-retention boundaries.

## 6. Cross-platform and framework decision

Retain Swift as the local mutation authority first. Extract contracts and durable local sessions without replacing working adapters. Future hosted orchestration belongs in private `CalshotWeb/Backend`, with additive owner-scoped migrations in that repository. Reuse its existing worker lease pattern, but separate agent jobs from calendar-sync jobs.

For the cloud phase, use **TypeScript + LangGraph with PostgreSQL checkpoints**, behind a thin model adapter. Domain records, grants and the action ledger stay outside framework-specific state. Do not combine two agent orchestration frameworks. Keep replayable planning/authorization nodes separate from external side effects: resumed graph nodes may run again, so writes must go through the durable action ledger and reconciliation.

A persistent worker claims/resumes jobs; website requests enqueue and stream/read state rather than owning long-lived execution. One action has one executor and fencing generation. Never race native and cloud executors or claim universal exactly-once provider delivery.

### Dispatch authority and recovery protocol

Initially Swift's durable local ledger remains the sole dispatch authority. The later cloud action ledger becomes the sole dispatch authority only for explicitly migrated operation families/executors; the native journal then records execution evidence under the same stable action/attempt IDs. Do not activate both authorities. Cutover requires drained or reconciled old attempts, an explicit ownership epoch and rejection of old-authority dispatch.

For migrated actions: (1) atomically claim an undispatched action with executor/epoch/lease; (2) native preflight checks current action, cancellation, policy revision, resource versions and allowance reservation, persists a prepared journal entry, and obtains cloud pre-dispatch acknowledgement; (3) atomically validate the current claim/lease/epoch and fence cancellation/revocation/policy changes against marking `attemptDispatched` in the authority ledger, and persist that marker before invoking the provider; (4) execute at most that attempt and persist provider response/receipt locally; (5) upload receipt evidence idempotently under the shared IDs, then attach receipts/settle reservations and mark reconciled. If the pre-dispatch acknowledgement or dispatched marker cannot be obtained, do not call the provider. A crash after the marker but before the call is conservatively uncertain.

A lease expiry MUST NOT reassign a dispatched/uncertain attempt. A new worker may reconcile evidence/provider state, not repeat the write; unresolved outcomes remain visibly interrupted. Lost receipt uploads retry attachment only. Revocation/Stop winning the dispatch fence prevents the call; once dispatch wins, an in-flight write may complete and its receipt must be preserved even after cancellation. Resume from a graph checkpoint rechecks authoritative action/cancellation/policy state; the checkpoint itself grants no dispatch authority.

Offline device execution stays under its separately scoped Swift ledger and device-local grants, with reconciliation on reconnect. It cannot claim a cloud ledger dispatch while disconnected or promise cross-device exactly-once delivery. Do not reroute an uncertain offline write to a cloud executor.

Device tools include capture, EventKit, local credentials and notifications. Offline/sleeping devices yield a visible waiting-for-device state. Cloud operations require separately authorized cloud connections and a compatible explicit billing route. Compatibility with the current ChatGPT-plan route is a release gate; adopting a framework must not silently switch users to paid API access.

Additional OS clients reuse React presentation and these typed contracts, with platform adapters for device functions. The choice of Electron, another shell or native Windows UI is deferred until a Windows spike; it is not required for the first agent improvements. Web mutations require the same verified policy/action contracts before controls are offered.

## 7. Speed and proactivity

Instrument before ranking bottlenecks. One request trace measures dispatch, credentials, image preparation, model first text/completion, each tool/provider page, coverage, policy, user wait, journal/write/receipt, first useful result and terminal outcome. Report p50/p95 by workflow/provider/source count/billing route. Exclude human waiting from system latency. Diagnostics omit prompts, screenshot data, event contents and credentials; remote sharing is opt-in.

First useful result means a sourced answer, actionable question/review, meaningful completed read, or saved task/operation receipt—not a spinner or generic preamble.

Initial experiments:

- Selected-event Add to Tasks is deterministic: zero model calls and no broad search.
- Bounded concurrent independent calendar reads, initially up to three, with per-account rate limits and coalesced credential refresh. Preserve adapter isolation, cancellation and per-source failure information.
- Replace array-only reads with coverage, freshness, completion, truncation and continuation metadata. Page/time/byte budget exhaustion is incomplete coverage, not an empty schedule.
- Only independent read tools run concurrently. Conflicting writes, dependent reads, questions and authorization transitions remain ordered.
- Show short receipt-based outcomes immediately without a mandatory final model round.
- Reuse image encoding/OCR by capture ID and avoid unnecessary rounds. Do not remove evidence from stateless requests until correction/extraction evaluations pass.
- Model optimization stays within the explicitly selected billing route and configured capabilities.

Proposed initial budgets, not current measurements: local feedback p95 ≤150 ms; task mutation and local receipt p95 ≤500 ms excluding provider revalidation; simple sourced calendar question normally ≤2 model turns; matched-fixture multi-calendar read p95 improves by at least 25% without lost coverage. Set absolute model/network budgets after baseline collection.

Proactivity starts with opt-in daily priorities, approaching-deadline risk suggestions and interrupted-work follow-through. Deterministic triggers/filtering precede model calls. Persist schedule timezone, cadence, dedupe key, claim/lease, required device, overlap/missed-run policy, quiet hours, snooze, notification/cost caps and disable state. Resolved tasks cancel obsolete nudges. Missed schedules coalesce instead of producing a burst. Background writes remain a later, separately granted capability.

## 8. Delivery sequence and agent assignments

| Phase | Work and ownership | Exit gate |
| --- | --- | --- |
| 0. Baseline and contracts | Execution lead: operation identities, publication/source separation, policy boundaries. Evaluation lead: traces and fictional failure corpus. | Agreed schemas and intentional contract amendments; baseline collected; no product behavior change from instrumentation. |
| 1. Fix current task intelligence (staged) | Native domain agent: calendar intent, source links, shared mutations and idempotency. Bridge/UI agent: trusted selection and direct Add to Tasks. Backend agent: additive task sync migration first. | 1a: device-scoped selected-event create-or-return with zero calendar writes; adapter recurrence identity and readable lookup gates pass. 1b: version-gated backend-first task migration, intent/provenance/conflict safety and bundle recovery pass before synced fields/task edits ship. Cross-device canonical linking waits for atomic registry acceptance; not a 1a promise. |
| 2. Fast authorized execution | Policy/execution agent: saved grants, origin envelopes, preflight and receipts. UI agent: Settings permissions and concise outcomes. | Granted routine requests need no extra review; device/service scope, direct-UI exact effects and atomic cumulative reservations pass; stale/ambiguous/ungranted actions pause; dispatch fences preserve in-flight receipts on revocation/Stop. |
| 3. Durable local sessions and memory | Session/memory agent: persisted runs/questions/waits and scoped summaries. UI agent: conversation selection and memory management. | Chat switching/restart preserves context; old actions cannot affect new runs; local memory works without embeddings; separate memory-sync consent and offline forget/summarization suppression pass. |
| 4. Shared private coordinator | Backend agent: LangGraph/worker/checkpoints/RLS/leases/device dispatch. Native adapter agent: typed execution handoff. | Private backend compatibility verified before release; sole dispatch authority cutover and every claim/ack/dispatch/upload crash boundary pass; no reassignment of uncertain writes; canonical registry acceptance if offered; offline device and explicit billing capability gates pass. |
| 5. Proactivity and other clients | Scheduler agent: opt-in suggestions and limits. Platform agent: Windows capability spike/shared UI; web mutations only after contracts. | No duplicate jobs/nudges, no foreground-grant inheritance, honest source freshness and unavailable-device behavior. |

Safe first-phase assumption: ship 1a only after its local identity/read-access gates. Keep its link/intent metadata in a device-local protected sidecar, excluded from the existing whole-document sync path, until the backend version gate ships; sync/history restore cannot erase that sidecar or confer ownership on a copied task. If safe isolation cannot be demonstrated, 1a also waits for the backend gate. Defer registry guarantees, saved grants and cloud execution to their own gates. Do not bundle the later framework migration into that delivery.

Read-only parallelization and deterministic receipts can ship alongside phases 1–3 once their correctness gates pass. Do not delay the concrete linking/permission fixes until the cloud migration.

The owner subsequently authorized implementation with GPT agents, then Sonnet 5.5 for challenging implementation and review; the original documentation-only restriction no longer applies. Use implementation agents with disjoint file ownership and explicit integration points. Review each phase before starting dependent phases. A planner/coordinator need not stay as an always-running LLM. Keep a separate evaluation/review assignment from implementation.

## 9. Verification and rollout

Contract tests are not evidence that the live model handles real requests well. Add live-model trace evaluations using fictional providers, fixed clocks and an isolated executor. Track tool/model rounds, questions, policy decisions, writes, affected identities, coverage, receipts, tokens and latency.

Release corpus must include:

- Existing all-day event → one linked task on the same device, zero provider writes; repeat across clicks/conversations/history restore. Phase 1a sidecar survives legacy sync/restore without leaking new fields or promoting copies; otherwise delivery waits for the backend gate.
- Tasks-only dated task versus newly published deadline, old-format decoding, strict sync validation and conflict-copy publication suppression.
- Same-title events across accounts, moved recurring occurrences, personal read-only source, unavailable device and revoked friend access.
- Task patch/completion/archive never modifies an existing source; changed source offers task-only refresh instead of overwriting.
- Corrections retained across model turns and restart; separate chats keep selection/context isolated.
- Changed target/grant/account while waiting; cumulative bulk limits and guest/invitation/sharing effects.
- Malicious screenshot/event/memory/tool text cannot confer permissions.
- Partial reads/pagination budget, partial writes, Stop, failed-only retry, transfer destination verification and unknown-outcome recovery.
- Worker/device crash around provider success, competing execution leases and no fallback replay.
- Memory forget/edit, cached summaries, account switch and background schedules.
- Legacy receipt precedence, dated-unpublished pending preservation, undated defaulted-none later dated versus explicit-none later dated; migration itself dispatches zero writes. Dated/undated conflict copies and source-linked copies stay suppressed/non-owning. Old whole-document writes cannot strip protected fields; old installations show update-needed with local edits retained.
- Concurrent local clicks return one device-scoped link; two offline devices create provisional records, then reconcile to one canonical registry owner without provider writes. Concurrent owner-scoped upserts, reconnect with a new connection UUID but stable subject, registry outage and conflicting local edits have explicit outcomes.
- Same provider IDs in different accounts/calendars remain distinct; moved original timed/all-day recurrence anchors stay stable. Calendar alias/route switch without verified event mapping cannot merge/promote identities. Exact read-only EventKit lookup succeeds, linking writes nothing, and write-target validation still rejects the source.
- Stable bundle/child IDs survive restart; proposal accumulation yields one review. Task save succeeds/provider fails; provider succeeds/receipt attachment fails; independent granted rows run while blocked/dependent rows wait. Retry reconciles evidence without recreating publication.
- Intent `new` → `none`/`existing` requires retain/remove choice; authorized removal failure/timeout/cancellation preserves recovery receipts. Retained inactive artifacts are never maintained by later task edits; suppressed copies never auto-publish after adding a date.
- Concurrent runs reserve cumulative grant bounds atomically; same-operation retry does not spend twice, uncertain effects retain reservations, and an additional real side effect needs new allowance. A synced grant label, reconnect, alias or generic UI button grants no new executor/resource authority; exact UI submission covers only displayed effects.
- Crash/network loss at claim, pre-dispatch acknowledgement, dispatched marker, provider response, local receipt and upload boundaries; lease expiry with dispatched/uncertain attempt never reassigns it. Cancellation/revocation on either side of the dispatch fence, checkpoint resume with changed policy, authority cutover and offline-native reconnect preserve evidence without replay.
- Account/history sync, OAuth and coordinator enablement leave semantic-memory sync off. Memory-bearing summaries cannot escape the toggle; stale offline replicas and retained history cannot recreate forgotten facts. Local phase 3 retrieval works without embeddings.

Hard gates require zero observed unauthorized/duplicate/replayed writes, invitation mistakes or false success in the release corpus. This does not claim every bug is prevented.

Implementation checks: WebUI tests/build; full native suite for bridge/calendar/session changes; backend versioned-write migration/RLS/atomic registry/reservation/dispatch-fence/lease rollback fixtures; private backend and website compatibility (unverified here and a blocking release gate); compact and expanded workspace/notch UI with long questions, twelve-row batches, keyboard focus and partial failures. No real calendar writes for automated verification.

Roll out independently behind flags: task linking, shared task mutations, concurrent reads, receipt-only outcomes, saved-grant direct execution, durable sessions/memory, coordinator, proactive suggestions, background writes. Rollback stops new dispatch/schedules while preserving journals, receipts, links and inspectable history; it does not replay or reverse completed work.

Before each phase, amend the applicable project/design/tool contracts deliberately. Saved authorization replaces unconditional per-write review only for matching grants; shared domain commands replace Tasks-page-only guards; explicitly authorized cloud execution replaces Swift-only ownership only for migrated operations. Current contracts remain in force until their replacement is implemented and verified.

## References

- [LangGraph persistence](https://docs.langchain.com/oss/javascript/langgraph/persistence): thread checkpoints and cross-thread stores.
- [LangGraph interrupts](https://docs.langchain.com/oss/javascript/langgraph/interrupts): resumable workflows and replay-sensitive node boundaries.
- [OpenAI Agents SDK sessions](https://openai.github.io/openai-agents-js/guides/sessions/) and [approval state](https://openai.github.io/openai-agents-js/guides/human-in-the-loop/): alternative runtime capabilities, not a replacement for the Calshot ledger or permissions.
- [OpenAI latency guidance](https://developers.openai.com/api/docs/guides/latency-optimization): reduce round trips, parallelize independent work and avoid unnecessary model calls.

## Scope of this planning work

The original planning commit (`6aa6cd5`) was research and design only; the implementation status below supersedes its implementation and verification limits. Live-model benchmarks remain unrun. This documentation follow-up resolves nine review findings as proposed normative contracts and acceptance gates; it does not establish private-backend compatibility or test results. Suggested defaults and latency budgets are proposed. No dependency installation, credential migration, backend deployment, DMG release or additional platform shell was performed.

## Task linking and permissions delivery — 2026-10-23

Implemented: explicit Tasks-only/publication/source-link intent, device-scoped exact source links, typed task tools, local operation receipts, versioned task sync, device-local saved task grants, task-only conversation/notch review and per-row outcomes. Calendar writes still require their separate review. The explicit Add to Tasks button uses the same permission ledger and may exceed automation quotas for its exact visible effect; it still consumes allowance for subsequent automated actions. Screenshot-started and default screenshot-import runs, including retries, do not inherit typed-request grants. Each bridge submission binds its own immutable prompt before asynchronous dispatch.

Verified: 251 native tests; 130 WebUI tests and a production build; 49 website tests against both pinned and current shared UI, plus 9 supplemental checks and both production builds; SQL rollback fixtures; hosted schema/history/security checks. Browser checks covered 920×650 and 1440×900, and the 560×490 notch with long review rows, partial errors and keyboard focus. Native UI automation could not start its connection; the isolated native fixture was built/launched but its rendering is unverified. Live-model traces, real-provider/EventKit parity and installed legacy-client rendering remain gates. See [verification notes](AGENT_PLATFORM_VERIFICATION.md).

Not delivered: calendar grants/automatic publication, durable multi-session recovery and semantic memory, cloud execution/coordinator, cross-device canonical link registry, background actions, proactive scheduling, additional OS clients or agent task reordering. Local task and permission ledgers retain evidence without pruning; their storage/performance redesign remains separate work. No updated DMG is released by this delivery.
