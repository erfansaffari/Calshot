# Apple design comparison and implemented polish

November 6, 2026. Calshot is a desktop calendar and task assistant. Its defining workflow is one conversation with precise, editable changes and native receipts. This pass preserves the local reference boards, sidebar, blue actions, source inspector, native capture and permission kernel.

## Design decisions

Use the system font with a 13px control/body base, 14px conversation text, 12px supporting text and a restrained 32px home heading. Keep semantic colors and both appearances. Quiet the light background gradient, give cards a visible boundary, and reserve the strongest blue for selection and primary actions. The source remains alongside the conversation when space permits, and becomes a focus-trapped dialog in compact windows.

Regular: `sidebar | conversation + aligned composer | optional source`
Compact: `sidebar | conversation + aligned composer` with source in a dialog.

This is specifically a productivity workspace: dense calendar content stays dense, while choices, reviews and controls have room to read. Extra glass, ornamental motion and a new visual theme would compete with the review. Existing notch timing stays unchanged.

## Comparison and changes

| Finding | Apple guidance | Implemented change |
| --- | --- | --- |
| Secondary text faded into pale surfaces | Accessibility › Vision; Color › Best practices | Light muted text changed from #737982 to #5f6875. On #eef3fa, contrast rises from 3.94:1 to 5.06:1; on white it is 5.64:1. |
| Destructive fill reused a foreground token in dark mode | Color › Best practices | Separate danger-fill tokens. White text on dark #bd3040 is 5.74:1. |
| Focus indicators were translucent; clipped choice outlines | Accessibility › Mobility and Speech | Two-layer solid focus ring, stronger field borders, padded choice list and inset month-chip outlines. |
| Selected navigation disappeared on hover | Familiar selection and immediate feedback; implementation judgment | Active styling persists; buttons and suggestions have hover/press feedback without moving hit targets. |
| Composer stretched far beyond its conversation and hid multiline drafts | Layout › Visual hierarchy | Constrain composer and status to the 760px reading column; grow drafts to 144px; preserve focus with read-only state during work and guard submission. |
| Source overlay allowed focus behind it | Accessibility › Speech; implementation judgment | Shared Radix dialog at compact widths, with Escape and focus restoration; existing native capture command retained. |
| Source-image text disappeared when changing appearance | Calshot screenshot-content contract; confirmed browser rendering issue | Source and history images use their own light color scheme so SVG source text stays unchanged in dark chrome. |
| Small checkboxes and utility controls | Accessibility › Mobility | Shared checkbox hit area is 28px; larger task checkboxes, mini-calendar arrows/days, calendar controls and month chips. |
| Mixed transfers did not identify every route | Layout › Visual hierarchy; Calshot interaction contract | Source → destination on each move, calendar on updates; shared banner only for an identical route. Before/after dates use the same formatting. |
| Disabled approval lacked a reason | Feedback and agency; implementation judgment | Persistent reason for missing destination or unresolved/unselected rows, associated with the approval button. |
| First message stayed in the ongoing-chat title | Calshot one-conversation contract; implementation judgment | Stable Assistant title and contextual subtitle. Home heading no longer duplicates h1. |
| Black notch inherited light hover surfaces | Accessibility › Vision | Dark semantic overrides on the compact black bar only; expanded content still follows appearance. |
| Talk button changed its element tree during a held press | Fluid-interface interruptibility; confirmed by component identity regression test | Stable VoiceBeam wrapper, release tracking across idle/live replacement, window pointer/key release and blur cleanup. Native token validation unchanged. |
| Accessibility surface preferences were absent | Accessibility › Vision; Motion; Materials | Opaque semantic surfaces for reduced transparency, stronger contrast mode, forced-colors checkbox fallback, existing reduced-motion behavior preserved. |
| Setup copy contradicted Autonomy | Calshot interaction contract | Neutral saving guidance in composer, questions and onboarding, rather than promising every request always opens approval. |

The guidance above uses the installed skills and their reference pages: `accessibility.md`, `layout.md`, `typography.md`, `color.md`, `designing-for-macos.md`, `buttons.md`, `motion.md`, `materials.md`, plus cross-platform/code-audit references. Primary references: [Apple accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [layout](https://developer.apple.com/design/human-interface-guidelines/layout), [color](https://developer.apple.com/design/human-interface-guidelines/color). Ratios are calculated from exact solid token pairs, not screenshots; they do not certify every composited pixel.

## Verification

- Production WebUI build passes; 174 WebUI tests pass. Four new regressions cover mixed-source calendar labels, stable talk-button identity, release after idle/live replacement and a single release on blur.
- Full native suite: 390 passed, zero failed. Used a clean `build/UIDesignVerification` directory after the existing DerivedData directory failed on a Testing.framework signature.
- Browser layout smoke checks: 12 isolated scenarios × two sizes (920×650 and 1440×900) × light/dark = 48 combinations, with no document-width overflow or React error fallback. These are layout checks, not a full accessibility certification.
- Inspected home, twelve-event review, six long choices and partial results; checked source-dialog Escape and return of focus to Show source. A four-line draft expands to 94px without internal clipping. Increased contrast plus reduced motion resolves to opaque surfaces and zero control transition duration in system dark mode.
- Rebuilt native WKWebView inspected with `--calendar-agent-demo`. No real calendar writes or paid voice sessions were used.

## Remaining limitations

- Native computer-use input repeatedly rejected resize attempts with “The user changed … Calshot.app”. Native appearance was inspected at the restored window size; exact compact/expanded dimensions were covered in the browser, not fully interacted through natively.
- Live audio and drawing-overlay release still need end-to-end hardware verification. Component tests cover the remount/release regression, and the full native suite passes; this does not prove every OS event path.
- Review selection still uses a shared pending state while the native command resolves. A future per-row interaction change needs a separate stale-token and keyboard-focus pass.
- Month-grid roving arrow navigation, comprehensive screen-reader/large-text testing, editor field-level validation and finer consolidation of feature-specific control styles remain future work. No claim of full HIG or WCAG compliance.
- Existing build warnings remain (bundle size, ignored Radix use-client directives, native headermap/Swift actor warnings).
