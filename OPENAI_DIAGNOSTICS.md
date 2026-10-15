# OpenAI connection diagnostics — October 14, 2026

The schedule capture in Memory 983D38E1-2387-44F8-85A9-A8FB3FAF5042 initially failed before a tool ran. Its old generic message did not retain the terminal failure reason, so that initial cause cannot be established retrospectively.

Verification with the existing API key:
- The same screenshot completed in a read-only Responses request.
- The full calendar-agent instructions and six tools also completed, returning create_events.
- The rebuilt app ran read_screen_text, then create_events, displayed two ready shift proposals, and received two added receipts after approval.
- API credit balance was $9.93. The organization spend limit showed “Limit not enforced.” gpt-6-luna had model/rate-limit access. No billing, limits, or keys were changed.

ChatGPT-plan connection:
- Fresh OAuth sign-in completed with the required chatgpt.tokens.use.direct scope and an issued client ID.
- GET https://api.openai.com/v1/models returned HTTP 520 in Calshot, Cloudflare reference a4a8916d1b33ab82-YYZ.
- An independent verified-TLS request with the same token also returned HTTP 520, reference a4a893a6680074a5-YYZ, with a short non-JSON error body.
- The root cause of that route failure is unconfirmed. API credit balance does not diagnose subscription-plan admission.
- The app now stores verified credentials before the model lookup, preserving successful sign-in when model access fails. It retries catalog selection on a later inference call rather than inventing an unavailable model.

Changes:
- Terminal stream failures retain message, code, parameter, incomplete reason, and response ID. Partial function calls remain non-executable.
- OAuth exchange failures preserve HTTP diagnostics.
- Settings distinguish sign-in success from model availability.
- A saved ChatGPT-plan / API-key choice makes billing-source selection explicit.
- Regression tests cover credential preservation on catalog failure and non-execution of partial tool output.
- All 77 tests pass. A live schedule loop completed; no automated calendar approval was performed.

The user explicitly chose the existing API key for future agent requests. Settings shows API key / gpt-6-luna; the choice is persisted and ChatGPT credentials remain available. The final build is running.
