# Task linking and permission delivery verification

Verified on 2026-10-23 using fictional task/calendar fixtures. This delivery covers task linking and device-local permissions; it does not complete the whole agent platform plan.

## Automated checks

- Native: 251 passed, zero failed or skipped. Result: `build/AgentPlatformReleaseTests.xcresult`; log: `build/agent-platform-release-native-tests.log`.
- WebUI: 130 tests passed; TypeScript and Vite production build passed. The final notch spacing change was additionally built and inspected in the browser.
- Website: 49 tests, typecheck and production builds passed against both the pinned Client and current working WebUI. Nine additional compatibility checks passed. External sibling-symlink verification used webpack because Turbopack restricts files outside its configured root.
- SQL: both disposable PGlite rollback suites passed, including the follow-up constraint aligning suppressed intent with native validation. Hosted migration history checksums match their immutable source files; catalog checks confirmed RLS, scoped grants, private fixed search paths and invoker wrappers. No hosted fixture identities or user task documents were changed for verification.
- Refreshed hosted advisors: zero security errors; the existing Auth leaked-password-protection warning remains. Performance Advisor showed no errors, warnings or suggestions.

## Behavior covered

- Exact selected-event linking creates or returns one device-scoped task, including personal read-only sources, with zero provider writes. Repeated operations return receipts; changed selections and ambiguous recurrence identity are rejected.
- Tasks-only dates do not publish deadlines. Conflict copies stay suppressed. Legacy decoding dispatches no writes; deleted-deadline metadata normalizes without discarding an owned or uncertain publication receipt.
- Task completion/archive preserves source/calendar metadata and does not require a writable calendar. Old operation receipts remain usable beyond 10,000 entries; malformed or duplicate receipt identities still fail validation.
- Saved task grants are off by default, scoped to owner/device/action/fields/expiry, and never authorize calendar writes. Expiry is preserved unless renewed deliberately. Explicit task review can exceed automation quotas for its exact effect, while retaining accounting for later automated actions.
- Default screenshot import and retries preserve their non-typed origin. Screenshot-created tasks also retain review. Each bridge submission supplies an immutable prompt, so another queued command cannot change its origin.
- Stop, stale review tokens, account/store changes and double approval are fenced. Completed rows keep receipts; unreadable outcomes pause further task writes until a clean reload and reconciliation.
- The direct Add to Tasks control uses the same ledger and an exact user submission, including when automated allowance is exhausted.
- Website loading is v2 first; only the exact missing-v2-function response falls back to v1. Errors remain persistent, metadata is retained, and native write/grant/review controls are unavailable on the website.

## UI inspection and limits

Browser inspection covered measured CSS 920×650 and 1440×900 workspaces, long titles, Tasks-only dates, expanded notes/reminders, inline title validation/focus, large task reviews, Settings controls and partial error rows. The 560×490 notch review keeps the heading, nested list and approval footer visible. A compact workspace header clipping issue and a notch footer clipping issue found during inspection were corrected and rechecked.

The isolated native fixture was built, signed ad hoc and launched with `--tasks-preview`. Native computer-use inspection failed twice with `Sky Computer Use native pipe startup failed`; actual native rendering and notch interaction remain unverified. Browser checks are not a substitute for that native gate.

Live-model extraction/tool traces and latency measurements were not run. Real provider/EventKit search-to-revalidation parity, installed older-client error rendering, cross-device canonical deduplication and concurrent hosted RPC sessions remain integration gates. Provider data was not modified for verification. Local operation/permission ledgers grow without pruning; a separate storage design is still needed for long-lived performance.

The compatible website loader must be deployed before enabling a v2 native build for real account sync. No updated DMG is part of this delivery. Durable multi-session recovery, editable semantic memory, cloud coordination, proactive scheduling and other OS clients remain future phases.
