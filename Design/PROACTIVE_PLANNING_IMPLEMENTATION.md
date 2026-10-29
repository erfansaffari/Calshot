# Proactive personal planning: implementation plan

Status: proposed, 2026-10-29. Source inspected; no runtime changes authorized by this document. Extends AGENT_PLATFORM_PLAN.md rather than replacing its identity, authorization, migration and recovery contracts. Existing uncommitted UI/calendar/reminder work is outside this plan.

## Outcome and first release

Calshot remembers explicit planning preferences, maintains separate persistent conversations, and proposes realistic daily/weekly work sessions around existing commitments. The first release is local to the Mac and works through the existing AI billing route. It does not require cloud orchestration or autonomous calendar changes.

First acceptance story: give Calshot three assignments and a week of commitments; save working-hour preferences; generate a feasible draft week; change one commitment; regenerate only affected sessions; restart the app and resume the same plan/conversation. Calendar publication stays explicitly approved. Tasks, deadlines and source links remain intact.

## Verified starting point

- Core/CalendarAgent.swift owns a single current session; start cancels the prior run, and the tool loop is bounded to eight rounds.
- Core/CalendarAgentToolExecutor.swift keeps question/approval continuations in memory. Those are not restartable workflow records.
- Core/ResponsesCalendarAgentClient.swift already abstracts model transport, streams responses and disables parallel tool calls. Preserve the selected billing route.
- MemoryStore.swift provides capture/history persistence and bounded historical context (12 recent records, 20,000 characters), not an editable preference database.
- CalshotTasks.swift already owns intent/provenance, source links, CAS versions and durable mutation receipts. Its task model does not yet contain a planning effort/dependency model.
- CalshotAgentPermissions.swift and Calendar/CalendarActionCoordinator.swift provide execution authority, validation, write evidence and recovery. Preserve these boundaries.
- WebWorkspaceState.swift, WebWorkspaceController.swift and WebUI own the shared snapshot/command presentation contract.
- The private repository already has Supabase and a TypeScript calendar-sync worker using claim/renew/complete/fail. Agent jobs must use their own records and queue.

## Stack decisions

Keep Swift/AppKit/SwiftUI + WKWebView for the Mac shell and native capabilities; keep React/TypeScript for shared presentation. An Electron rewrite is not a prerequisite.

Introduce an account-scoped SQLite store for new sessions, memory, plans and feedback, behind Swift repository protocols. Use SQLite transactions, migrations and indexed queries. Choose a maintained Swift wrapper during the dependency spike; keep its types out of domain contracts. Do not replace existing history/task/permission stores in the first release. They remain authoritative for their own records; new plan records reference them by ID/version. Stage any later ledger migration separately with crash recovery tests.

Use Swift for the initial pure scheduling engine so local planning does not depend on a new server or JavaScript write logic. When other platforms need planning, port this bounded pure engine to the private TypeScript backend against a shared fixture corpus, then choose one authoritative planner per request. Avoid embedding a Node runtime in the Mac app just for orchestration.

Use TypeScript/Node for the future private coordinator, LangGraph for durable model workflows, and Supabase PostgreSQL for app-owned records and persistent graph checkpoints. Keep Next.js/Vercel for the existing website/API. Run the agent worker as a separate long-lived container/service; website requests enqueue work and return/stream status. Hosting vendor selection depends on existing infrastructure and measured workload.

Reuse the existing leased-job pattern first. Supabase Queues is an optional queue implementation, not a second scheduler introduced alongside another equivalent queue. Cron only wakes/queues eligible jobs; it must not perform long model workflows. No Redis or separate vector database is required initially. PostgreSQL full-text search plus structured preference lookup is sufficient before semantic retrieval is justified; pgvector can be added later.

Use one orchestration framework. LangGraph checkpoints represent workflow state, not permission or proof of a provider write. Keep model transport behind an adapter and explicitly test current ChatGPT-plan compatibility before any cloud cutover. Local authorization tokens and provider credentials are never copied into the cloud coordinator.

## App-owned records

All records carry owner ID, version and timestamps as appropriate. Dates preserve date-only semantics; timed intervals retain timezone and UTC instants.

- Session: conversation ID, title, objective, linked tasks/plans, summary version, privacy scope.
- Run: session ID, origin, executor, billing route, lifecycle, cancellation generation, parent run, bounded execution budget.
- PendingInteraction: question/review ID, exact payload, versions/digest, scope, answered/cancelled state. Persist before showing controls.
- MemoryItem: typed preference or fact, explicit/inferred source, source references, confidence, scope, expiry and deletion/suppression version.
- PlanningTaskMetadata: task ID/version, estimated and remaining effort, estimate source/confidence, earliest start, priority, dependencies, preferred/minimum/maximum session lengths, split policy. Keep this as a sidecar initially so v2 task sync cannot strip new fields.
- Plan: day/week horizon, timezone, source revisions, coverage/freshness, preference versions, algorithm version, status, revision and explanation.
- WorkSession: task ID, plan ID, start/end, pinned status, proposed/scheduled/completed/skipped state and optional owned calendar receipt. It is neither a deadline nor a source event.
- Feedback: explicit completion, user-reported actual effort, move/rejection with optional reason, associated plan/session/version.
- ProactiveJob: trigger, timezone, next eligible instant, dedupe key, capability requirements, privacy scope, cost/notification limits, quiet hours and cancellation state.

Existing task completion does not prove actual time worked. An elapsed calendar block does not prove completion. Learned preferences never become grants.

## Planning algorithm

1. Load a bounded, fresh agenda with per-calendar coverage/error information, tasks and applicable preferences. Missing coverage is unknown availability, not free time.
2. Build busy intervals, working windows and buffers. Expand recurring occurrences correctly; treat all-day deadlines as dates, not occupied working hours. Explicit all-day commitments may block the day according to their availability semantics/user choice.
3. Resolve effort from user estimates first. A model may suggest a range and breakdown when absent; mark it as an estimate and allow one grouped correction. Never present inferred effort as fact.
4. Validate dependencies, detect cycles, then place candidate sessions using deterministic ordering by deadline feasibility, dependency readiness and user priority. Score alternatives for preferred hours, fragmentation and changes to an accepted plan.
5. Enforce hard constraints: no collisions with known busy intervals, deadline boundaries, pinned blocks, valid durations and dependency order. Soft preferences may be relaxed only with a visible explanation. Return unscheduled effort and conflicts when capacity is insufficient.
6. Replan from the previous revision, preserving completed/pinned sessions and minimizing movement. Source changes invalidate affected proposals; a stale plan cannot publish without fresh validation.
7. Return a structured diff. A short model explanation is optional; generating the actual schedule must not require repeated model tool rounds.

Plan state: draft -> validated -> awaiting publication -> partially published/published. Replanning creates a new revision. Work-session publication is a bundle of stable action IDs with per-row receipts, not an atomic provider transaction. Unknown outcomes reconcile before retry; successful rows are never replayed.

## Memory and context assembly

Start with explicit preferences and user-approved suggested memories. Retrieve a small context package: current conversation, relevant task/project facts, applicable preferences, agenda coverage and referenced outcomes. Do not append all history or every agent's transcript to every request.

Create bounded session summaries with source references and versions. The coordinator knows each session's objective/status/blocker; it retrieves detailed messages only when needed and permitted. Shared-calendar restrictions propagate into summaries and memory candidates.

Add Settings memory inspect/edit/forget controls. Forget removes retrieval entries and invalidates summaries/embeddings; suppression tombstones prevent retained history or offline replicas from recreating the same forgotten fact. Explain source-history retention separately.

Semantic-memory sync is a separate explicit opt-in. Account sync and cloud orchestration cannot enable it. Local-only memory must not leak through cloud session summaries. Sending selected context to the user's chosen model route remains distinct from cloud persistence and must be explained.

Learning follows explicit feedback first. Repeated rescheduling can create a suggested preference, not a silent hard constraint. Preserve conflicting evidence and expiration. No fine-tuning is needed for the initial learning experience.

## Execution and cross-device authority

Swift remains the only local mutation authority. Planner/agents produce typed proposals; the current kernel/coordinator validate and execute. Existing grants cover only implemented typed task requests. Proactive suggestions may be generated without calendar writes; background execution and automatic work-session movement require new separately authorized policy contracts.

Future automatic maintenance may affect only eligible Calshot-owned work sessions within saved scope. It cannot move meetings, source-linked events, deadlines or guest-bearing events merely because the plan would fit better. A notification is not approval.

Follow AGENT_PLATFORM_PLAN.md's explicit cloud dispatch cutover: one authority epoch and executor per action, persisted pre-dispatch acknowledgement, native evidence under the same action ID, and reconciliation of uncertain attempts. Lease expiry does not prove that an external write did not occur. No blanket exactly-once claim.

Device-bound actions wait for the Mac when it is offline/asleep. Cloud-authorized provider access is a separate capability. A local-only AI billing route cannot run while its device is unavailable; never silently fall back to paid API use.

Cross-device linking still needs an owner-scoped canonical link registry and verified provider occurrence identity. Calendar display aliases are not proof of event equivalence. Keep current device-scoped guarantees until those gates pass.

## Delivery sequence and source changes

### 0. Stabilize and measure

Preserve and separately verify the existing uncommitted changes. Add bounded redacted timing spans around dispatch, context reads, first useful result, model rounds, provider reads and execution. Measure native/React snapshot costs before UI optimization. Establish fixtures for one-day/seven-day plans, sparse/full calendars and partial provider failures.

### 1. Durable local sessions

Add Core/AgentSessionStore.swift, Core/AgentRunCoordinator.swift and Core/AgentContextBuilder.swift. Refactor CalendarAgent.swift into a per-run execution object; replace singleton mutable executor state with run-scoped state. Wire CalshotModel+CalendarAgent.swift and shared snapshots to an active session ID. Start with multiple saved conversations and one foreground executor; concurrent workers come only after isolation tests pass.

Persist questions/reviews as records; on resume revalidate current policy, task/source versions and user identity. Never serialize continuations or restore old approval as permission for new work. Import old history read-only by stable IDs, retaining the old store for compatibility.

Gate: restart while awaiting a question/review, switch chats, stop after partial success, and verify no context leakage or replay.

### 2. Explicit memory

Add Core/PersonalMemoryStore.swift and the context retrieval layer. Extend WebWorkspaceState.swift, WebWorkspaceController.swift, WebUI/src/types.ts and Settings with allowlisted scoped memory commands. Keep MemoryStore.swift as capture/history storage rather than overloading its meaning.

Gate: a saved preference affects a new chat; edit takes effect immediately; forget survives restart and retained history. No memory-derived authorization.

### 3. Daily/weekly planning MVP

Add Core/PlanningTypes.swift, Core/PlanningEngine.swift, Core/PlanStore.swift and Core/PlanningCoordinator.swift. Add planning metadata sidecars referencing CalshotTask versions. Extend agent tools with build_plan/read_plan/revise_plan backed by native validation. Preparation and publication are separate operations.

Add compact Today/Week plan presentation using existing shared tokens and conversation cards. Preserve the current calendar grid; show only accepted/published sessions as real events, or clearly marked optional draft overlays. Keep questions and plan changes usable in the notch. A task page remains the canonical task editor.

Wire approved publication through CalendarActionCoordinator, keeping work-session receipts separate from CalshotTask.deadline receipts. A user moving a provider block invalidates its prior version; it is not silently moved back.

Gate: the first-release acceptance story passes, including DST, all-day dates, impossible workload, unknown duration, source failures, stale plans and partial publication.

### 4. Local proactive suggestions and learning

Add a persisted trigger evaluator and feedback store. Triggers: start-of-day/week, deadline risk and changed commitments. Debounce event bursts, dedupe suggestions, honor quiet hours and cap notifications. Sleep/wake catch-up produces one current suggestion, not a burst of missed jobs. Expose snooze, dismiss and disable.

Reuse the notification service but verify actual permission/delivery separately from job creation. Begin with suggestions; automatic execution stays disabled until the new background authorization contract exists.

Gate: repeated triggers create one suggestion, completed tasks cancel obsolete reminders, timezone changes update eligibility, and ignored suggestions do not become increasingly noisy.

### 5. Private coordinator and additional clients

Place hosted implementation only in CalshotWeb/Backend: proposed src/agent/{contracts,context,graphs,dispatch,memory,planning} and src/agent-worker.ts. Add owner-scoped Supabase migrations for sessions/runs/actions/plans/memory/jobs and RLS tests. LangGraph owns workflow checkpoints; application tables own identity, authorization, plan versions and action receipts.

Start cloud planning/read-only jobs, then migrate execution families deliberately. The website enqueues/renders, the worker plans, and the native device executes device-bound commands. Add version negotiation and deployment ordering before any client starts writing a newer protocol. Never extend the whole-document task sync blindly with new planning fields.

Gate: worker crash/restart, duplicate queue delivery, stale worker, device offline, account switch, revoked grant, memory-sync off and unknown provider outcome all behave correctly. Validate the selected billing route end to end.

Only then choose the Windows/mobile shell through a platform capability spike. React presentation and versioned contracts are reusable; capture, credential storage and notifications still need platform adapters.

## Speed and evaluation

Proposed budgets, not measured claims: local input feedback p95 <100 ms; cached Today read p95 <200 ms; pure seven-day planning over a bounded 100-task fixture p95 <500 ms on the supported Mac. Measure cloud/model first-useful-result separately; do not count a spinner or preamble as useful completion.

Use direct commands for exact controls, bounded concurrent independent reads, cached encodings/OCR per capture and context assembled to a token budget. Preserve provider coverage and account-generation checks. Model-requested writes remain ordered through the execution authority. Delegate only substantial independent reasoning and cap child depth, time and spend.

Acceptance corpus: no conflicting scheduled blocks; no deadline/session confusion; zero duplicate writes on retry; honest capacity shortfall; pinned-session preservation; no cross-account/session leaks; malicious event text cannot grant authority; revoked memories cannot reappear; no autonomous calendar edits without their new scope.

Run pure planner tests and property/invariant tests, session/memory migration tests, model behavior evaluations, full native suite for bridge/session/calendar changes, WebUI tests/build, website compatibility checks, SQL isolation/recovery tests and actual native compact/expanded visual checks using fictional data. Report live-model latency and notification delivery separately from unit-test results.

## Documentation consulted

- https://docs.langchain.com/oss/javascript/langgraph/persistence
- https://docs.langchain.com/oss/javascript/langgraph/interrupts (resumed nodes can rerun; side effects require independent idempotency/recovery)
- https://supabase.com/docs/guides/queues
- https://supabase.com/docs/guides/cron

This planning pass did not run builds/tests, deploy infrastructure, alter permissions, publish a release or write calendar data.
