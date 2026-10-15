# Calshot project rules

Read [Design system](Design/DESIGN_SYSTEM.md) before changing product behavior or UI. The approved visual reference is [Calshot.html](Calshot.html); the product context is [DESIGNER_HANDOFF.md](DESIGNER_HANDOFF.md). Preserve that reference file unchanged.

## Architecture
- React/TypeScript in WebUI owns workspace presentation. Swift owns permissions, capture, credentials, agent sessions, calendar operations, validation and persistence. Never duplicate write logic or credentials in JavaScript.
- Use shared tokens/components. Keep one source of truth: native snapshots are authoritative; frontend local state is only for unsaved input and presentation.
- Every bridge action must be allowlisted, validated and scoped. Approval must validate the current review token; question responses must identify the current question. Reject stale actions. Never auto-approve writes.
- Preserve native capture, shortcut, notch, menu bar, account authorization and interrupted-write recovery when changing the workspace.

## Product behavior
- The notch follows the compact reference in Design/Notch-reference.png. Keep capture, questions, review, editing, approval, errors and follow-ups inside it; opening the full app must be optional. Reuse shared React components and native session/approval validation.
- Keep questions, approvals, progress and outcomes within the task conversation. Present normal language; hide setup and diagnostics in advanced settings.
- Every feature needs empty, loading, success, error, cancelled and interrupted states where applicable. Put errors next to the affected field, row, account or task. Do not use a fleeting toast for an actionable failure.
- Calendar success comes from receipts, never assistant prose. Retry failed rows only. Missing date/year/time stays unresolved. Deletes begin unchecked. Transfers use one approval and verify the destination before removing the original.
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
