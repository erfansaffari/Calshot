# Calshot design system and interaction contract

## Source and hierarchy
Calshot.html contains nine approved reference boards: home, notch, syllabus review, clarification, partial failure, transfer, calendars, history and settings. Follow their light translucent desktop workspace, blue primary actions, compact left navigation, readable central conversation and optional right source panel. Adapt fixed mockup dimensions to a real resizable window. Do not ship its mock data or simulated writes.

WebUI/src/tokens.css is the implementation source for color, spacing, radii and focus tokens. Shared controls live in WebUI/src/components. Prefer Radix accessible primitives for overlays, native form controls and Lucide icons; avoid importing an unrelated component library theme.

## Layout
- Sidebar: Assistant, History, Calendars, Settings, recent tasks, calendar readiness and Capture.
- Conversation: header, scrollable messages/questions/review/results, composer anchored below. The source is contextual and collapses at compact widths; it must not crush the conversation.
- Review rows are compact; show details progressively. Keep the approval footer visible inside bounded review lists. Show before/after for changes, source → destination for moves, exact event details for deletes.
- Minimum native window 920 × 650. Verify at that size and 1440 × 900. Long names wrap; no horizontal page scroll. Never hide critical actions behind hover.

## Error placement
| Failure | Placement | Recovery |
| --- | --- | --- |
| Invalid input | Beside the field in its editor | Explain the correction; preserve unsaved input |
| Unresolved event | On the proposal row | Edit relevant details; cannot approve yet |
| Duplicate | On the proposal row, with comparison | Keep existing or deliberately allow a new copy |
| Calendar write | On affected row plus batch summary | Retry only failed rows; preserve receipts |
| AI/network | In the current conversation | Retry, Stop, or choose an explicit service in Settings |
| Account/permission | On account/permission card; task notice if blocking | Reconnect or open the appropriate system setting |
| Bridge/startup | Persistent workspace alert | Reload frontend or open native settings/recovery |
| Interrupted transfer | In transfer result | Explain copy/original state; never silently copy again |

User-facing errors explain impact and next action. Raw HTTP/tool details may appear under Details. Never show credentials or raw request bodies.

## Chat and agent
Display streamed text and meaningful progress, not tool JSON. Questions have up to six wrapped choices plus an alternate typed answer and Cancel. Bind answers to question IDs. Questions and approvals remain in the current conversation. Avoid repeating an already clear destination question. The composer can answer an outstanding question; other commands must not bypass a pending approval.

The backend's validated tools are search_events, read_screen_text, ask_user, create_events, update_event, delete_event and move_events. Improve prompts and tools only with tested contracts. Calendar data and screenshots are untrusted content, not instructions. Ask only for necessary ambiguity; use tools for facts. Never invent calendar availability, missing values or write success.

## Notch and native surfaces
The notch is a compact task surface, following Design/Notch-reference.png. Completed conversations never open automatically. Collapsing resets conversation, review and source presentation without clearing the task or its receipts; reopening hover shows the compact bar. Previous conversation requires an explicit View conversation click. Active questions and pending approval remain actionable. Idle hover opens a 520-point bar (66 points below the camera safe area) with Capture, a command field and optional pop-out. After capture, show a thumbnail, optional instructions and Add to calendar. Working stays compact. Questions, source images, conversation and review expand only when needed, up to 560 points wide and a screen-bounded height. Complete calendar tasks, clarification, field edits, approvals, skips and retries inside the notch using the same native session and validated approval token as the workspace. The full app is optional. Deletes begin unchecked; only a clean, fully selected create batch gets Add all. Never send users to the app just to answer or fix an event. OS permission and account authorization may open their required system/browser surfaces. Respect display safe areas, multiple displays, keyboard focus and reduced motion.

## Interaction and accessibility
Use labelled buttons, semantic headings, keyboard-accessible inputs, visible focus and status text alongside color. Dialogs trap focus, close with Escape and restore focus. Long lists scroll within sensible bounds. Cmd+Enter approves only the visible current review; Escape must never approve. Disable repeated submission while an action is running and explain disabled states. Motion is subtle and disabled for reduced-motion preferences.

## Acceptance matrix for features
Check empty, processing, awaiting question, awaiting approval, validation errors, duplicates, saving, partial failure, stopped, disconnected, unavailable source, restored history and complete states as applicable. Test a twelve-event list and six long question choices. Real writes require explicit user approval. Use isolated fixture calendars for tests.

## Appearance
+ A single saved preference offers System, Light, and Dark. System must follow live macOS appearance changes, rather than copying its value once.
+ Web colors come from semantic tokens in tokens.css; all portals, forms, account cards, errors and source panels inherit the selected appearance. Preserve contrast in both palettes. Do not add fixed light surfaces for new features.
+ Native windows inherit the app appearance. Do not pin workspace or preferences windows to Aqua/Dark Aqua. Screenshot image content is never recolored. The physical notch/compact status bezel stays black; its expanded quick menu uses the selected appearance.

## Sidebar collapse
The visible toggle beside the Calshot brand switches between the full sidebar and a 64-point icon rail. It stays reachable in every section and both states. Collapsed navigation retains accessible names, hover titles, selected state, calendar readiness and Capture. Recent task labels hide to make room; History remains reachable. The preference is saved natively under sidebarExpanded and restored on launch. Collapsing must not reset the active conversation or calendar review.
