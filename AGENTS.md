# Calshot project rules

Read [Design system](Design/DESIGN_SYSTEM.md) before changing product behavior or UI. The approved visual reference is the optional local `Calshot.html` at the project root; it is ignored by Git and is not required to build or run the app. Preserve it unchanged when present, and use the tracked design system when it is unavailable. The product context is [Design/DESIGNER_HANDOFF.md](Design/DESIGNER_HANDOFF.md).

## Architecture
- React/TypeScript in WebUI owns workspace presentation. Swift owns permissions, capture, credentials, agent sessions, calendar operations, validation and persistence. Never duplicate write logic or credentials in JavaScript.
- Use shared tokens/components. Keep one source of truth: native snapshots are authoritative; frontend local state is only for unsaved input and presentation.
- Every bridge action must be allowlisted, validated and scoped. Approval must validate the current review token; question responses must identify the current question. Reject stale actions.
- Task actions and calendar writes save immediately only through a saved, explicit, device-local grant the user set in Settings. Native code owns the grant, the review and execution through the permission kernel; a grant is created only from the validated Settings callback and is never derived from model output, chat text, foreground state, history, account sync or a one-off review. Default is review. Task grants cover create, link, edit, complete and archive, and only a request the user typed; a screenshot-capture run always uses the task review. Without a matching task grant, the agent shows one task-only review in the current conversation or notch bound to the run, owner, store, selected context, expected versions and digest. A visible task review of the exact effect is operation-scoped authority and may exceed the saved per-request and per-hour quotas, which still count toward later automatic use. A task grant never covers calendar writes, deadline publication, guests, series or sharing. Calendar grants cover only adding events and editing event details, scoped to the writable calendars the user chose (default the selected destination), requested-only, and off until saved. They apply to a request the user typed or spoke; a screenshot-capture run always uses the calendar review. A fully resolved row (confirmed year, unambiguous date, start and end or explicit all-day, title, no duplicate, no guests, not recurring, one event) is reserved and written through DirectCalendarWriter. Unclear, out-of-scope, over-quota, delete and move rows stay in the calendar review. Rows apply independently. Background task and calendar actions do not exist. If the permission store cannot be opened or read, task changes and automatic calendar saves are blocked and the error stays visible; never reset or overwrite the saved file.
- Preserve native capture, shortcut, notch, menu bar, account authorization and interrupted-write recovery when changing the workspace.

## Product behavior
- The notch follows the compact reference in Design/Notch-reference.png. Keep capture, questions, review, editing, approval, errors and follow-ups inside it; opening the full app must be optional. Reuse shared React components and native session/approval validation.
- Keep questions, approvals, progress and outcomes within the task conversation. Present normal language; hide setup and diagnostics in advanced settings.
- Every feature needs empty, loading, success, error, cancelled and interrupted states where applicable. Put errors next to the affected field, row, account or task. Do not use a fleeting toast for an actionable failure.
- Task success comes from the native task receipt after the save is persisted, shown per row; rows apply independently, so partial results are reported and never described as all-or-none. Calendar success comes from receipts, never assistant prose. Retry failed rows only. Missing date/year/time stays unresolved. Deletes begin unchecked. Transfers use one approval and verify the destination before removing the original.
- Keep source calendars and destinations visible. Search all connected readable calendars; distinguish empty results from incomplete searches. Reuse existing connection routes rather than duplicating calendars.
- Stop preserves completed writes. History restore never replays writes. New sessions invalidate stale tool results and frontend actions.

## Change and removal workflow
1. Map the feature to existing agent, coordinator and persistence contracts before editing.
2. Update shared state/types and native validation together. Avoid orphan controls and unsupported promises.
3. When removing a feature, remove its controls, commands, subscriptions and documentation; preserve backwards decoding of history.
4. Run WebUI build/tests and the relevant native tests. For bridge/calendar/session changes run the full native suite.
5. Inspect the actual native app and browser preview at compact and expanded sizes; cover long choices, large batches, partial failures and keyboard focus. Use isolated fixtures, never real calendar writes for verification.
6. Report actual verification and remaining limitations. Do not claim that all bugs are prevented.

Do not expose secrets, use fictional data in fixtures, and never replace a selected AI billing route silently.
