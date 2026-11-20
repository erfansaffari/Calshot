# Agent architecture: context, memory, voice and proactivity

Status: adopted 2026-11-18; phase 1 implemented the same day. This records what Calshot's agent sends to the model, how it remembers, how voice speaks, and why. It is based on a review of current research and of open-source agents (OpenClaw, Letta, Mem0, Graphiti/Zep, Claude Code, Codex, Hermes, goose, Clicky, OpenMausBot, Dayflow, Coast). It complements [PERSONAL_AGENT_PLAN.md](PERSONAL_AGENT_PLAN.md) and the rules in AGENTS.md.

## The goal, and the constraint

Calshot should become faster, cheaper and better at knowing the user, and it must not get worse at answering. No change ships on the argument that it "should" help. Each change is measured against fixtures of the failures that matter for a personal calendar agent, and the typed agent records its speed and token use per run (`AgentRuns.jsonl`, numbers only).

## What the evidence says

- **Long context gets worse as it grows.** Chroma's study of 18 models (July 2025) found recall falling as irrelevant input and near-miss distractors grow. More memory in the prompt is not more intelligence. A small, current, relevant slice beats a large one.
- **Never rewrite the memory store.** ACE (ICLR 2026) shows a single "rewrite everything into a summary" step collapsing 18,282 tokens to 122 and dropping accuracy from 66.7% to 57.1%, below having no memory at all. Memory changes must be small deltas: add, reinforce, close, forget.
- **Outdated is not old.** The temporal-graph approach (Graphiti/Zep) closes a fact's validity when a newer fact contradicts it, and keeps it as history. Letta's reflection rule says the same: fix the stale entry at its source and do not keep two contradictory current facts. An old fact that is still true stays. An old conversation is how Calshot answers "what did we decide in March"; it is never deleted for being old.
- **Leaderboards disagree.** Mem0's own table has full context beating Mem0 when the history fits (72.9 vs 66.9), while Zep beats full context on long histories and loses on knowledge updates with a smaller model. The stable requirement for this product is the update case, so Calshot adopts the update rule, not a memory service.
- **The prompt prefix must be stable.** Agent loops read about 100 input tokens per output token (Manus). Cached input is several times cheaper, and any change early in the prompt (a timestamp, a reordered tool) throws the cache away. Context is appended after the stable part.
- **Clear tool payloads before summarizing anything.** Anthropic's context editing removes stale tool results and keeps the conversation. The live request and the receipts that authorized a write are never summarized.
- **Voice must not rely on a style sentence.** OpenAI's own audio instruction-following test scored 30.5%. Shorter speech needs structure: a short voice prompt that leads with the style, and a voice model that only speaks while a backend does the work.
- **Interrupt only at boundaries.** Timed help was accepted 67.6% of the time against 38.8% when mistimed (N=32). Suggestions made at a workflow boundary were engaged 52% of the time, while mid-task ones were dismissed 62% of the time. Calshot speaks unprompted only for alerts the user set, and shows other suggestions visually at a boundary.

## Decisions

### 1. Memory: three layers, validity instead of age

- **Semantic: current knowledge.** Facts, preferences, people, routines, style and goals, each with its source, confidence and evidence count. Only this layer is ranked into the request, within a fixed budget. When a newer statement replaces an item, the item keeps its id and takes the new text. The old text becomes a **history entry** with the dates it was valid. It is no longer forgotten with a tombstone. History stays on this Mac, is never sent to the account copy, and is shown by `recall` only as "no longer true since…". A replaced text is not re-learned by inference; only the user saying it again makes it current again.
- **Forgetting stays absolute.** A forget, by the user or of an inference, tombstones the text so it is never learned again.
- **Episodic: conversation notes.** One dated note per conversation, kept up to 2,000 and never ranked by age alone. Each request gets the newest notes plus the older notes that match the request. `recall` searches all of them.
- **Raw transcript.** The full chat stays on disk and is searchable with `get_conversation_context`; the request carries only the recent window.
- **Unconfirmed inferences fade.** Low-confidence inferences still expire after 90 days unless seen again. Their weakness is uncertainty, not age.
- **Inferences from the screen** enter requests only after they are seen a second time. A page the user glanced at cannot plant a "preference" on its own (memory poisoning).
- **When memory is full,** the oldest closed history goes first, then the weakest inferred item. Nothing the user said is dropped.

### 2. Context assembly: stable first, relevant second, fresh last

In order:
1. Fixed instructions and tool schemas (cached).
2. Who the user is, ranked current knowledge, the calendar profile, recent and relevant notes.
3. Recent conversation turns and clipped earlier tool results.
4. The near-term schedule, read natively.
5. The clock and alert setting.

Within a run, the conversation is append-only, so every later step reuses the cached prefix. The near-term schedule is preloaded for typed requests as it already is for voice, so "what's on today" needs one model call instead of two.

### 3. Compaction

Calshot's one ongoing chat never grows without bound in the request, because the request carries a window, not the whole history. Compaction therefore means, in order:
1. Old tool payloads leave the request first, as clipped excerpts. A receipt is never edited.
2. Old turns leave the window by age only after the reflection pass has had the chance to save their durable facts and a note.
3. The current request and the current run are never summarized.
4. The memory store is never rewritten by a model.

### 4. Voice: ears, one brain, mouth

Measured 2026-11-19: a GPT-Live request spent 10.1 s in the agent (7.3 s to the first text) for two model calls of 28,788 input tokens with none cached, because every request re-sent the 46,000-character typed prompt with the context inside it. HeyClicky's voice is fast for structural reasons visible in its app (1.1.3): listening is warmed before the key is pressed, the model's prompt cache is warmed ahead of time, context is prepared while the user talks, one fast model call writes the spoken sentence and the tool calls, and speech is generated line by line. Calshot now does the same:

First live session on the new pipeline, 2026-11-19: release to first audio 6.1 s and 6.7 s. Words 0.5 s; a cold first screen capture held the agent 0.9 s; the agent took 2.8 to 3.5 s to its first text with 0 of 13,561 and 14,997 input tokens cached; speech took 1.1 to 1.6 s through the server. The fixes below (a per-session `prompt_cache_key`, byte-stable request JSON, a 0.4 s screen wait, warm capture, and early speech for a locally verified session) target each part; the logs (`com.calshot.voice`, `com.calshot.agent` speed) report the model, tier and cached tokens per request and the server's `Server-Timing`.

- **Ears.** `GeminiEars` streams the held audio to `gemini-3.5-transcribe-live` through a one-use listening token from Calshot's voice server. The connection opens when voice starts; audio held before it is ready is buffered. Measured against the live service: the final words arrive about 0.26 s after release, in English and Persian, and calendar words in the token's vocabulary are spelled as the calendar spells them ("CS 245").
- **Brain.** `VoiceBrain` keeps one append-only conversation per session: the fixed voice prompt (speaking style, then every typed-agent rule, then the voice rules) as the leading developer message, then what Calshot knows (memory, earlier conversation, the schedule snapshot), then each turn (native context, then the words). Each request starts with the whole previous one and carries the session's `prompt_cache_key` (the ChatGPT plan caches nothing without one, as measured), with sorted JSON keys, so the provider's cache covers the prefix; the prefix is read into the cache at session start while the user is still talking. Each request goes to Calshot's voice server (`/api/voice/brain`), which runs it on GPT-6.1 Sol with the Ultrafast tier, low reasoning effort, low verbosity, a 2,000-token output limit and `store: false`, with Calshot's OpenAI key; the owner chose this on 2026-11-19 after the third live session showed that ChatGPT plans list no Ultrafast tier for any model (every plan model offered only "priority") and answered on the default tier. Measured with the server's key on a 15,800-token voice prompt: first text in 1.4 s uncached and 0.8 to 1.1 s cached on Ultrafast, against 1.5 to 2.5 s on the default tier and 1.5 to 3.5 s on the plan. Typed requests, reflection and other model work stay on the user's selected route. The schedule snapshot answers "what's on Friday" in one call. Before a tool the model says a two-to-four word acknowledgement, and the answer after the tool never repeats it.
- **Mouth.** `VoiceMouth` sends each sentence to `gemini-3.8-flash-lite-tts` through the voice server as soon as it is complete, fetches one sentence ahead and plays them in order. First audio arrives about 0.7 s after a sentence is sent. Speaking ends when the last sentence has arrived and the speaker is quiet, so the state cannot stick on "speaking".
- **Screen.** The capture starts when the key is pressed and screen capture is warmed when voice starts. The agent waits at most 0.4 s after the words for the screen text; when it is late the turn says so, and `look_at_screen` waits for that same capture. A drawing always waits, because its picture is the subject.
- **Turn rules.** Holding the key while Calshot speaks stops it at once, tells the next turn the user cut it off and replaces a request still running unless its review is open. Typed messages during voice take the same path without the ears. A spoken alert is a tool-free turn. A review is announced by Calshot itself, once.
- **Server.** `Server/` (Vercel `calshot-voice`) holds the Google and OpenAI keys, checks the session signature locally (Supabase's published ES256 keys) so speech can start while it draws on the allowance through `consume_voice_allowance` (a refusal cancels the speech before any audio is returned; a session it cannot check waits for the database) (verified, non-anonymous accounts; 60 listening sessions, 40,000 spoken characters and 400 model requests per UTC day), mints listening tokens locked to the transcription setup, relays speech as raw PCM, relays the brain's Responses stream (conversation items and function tools only; model, tier and limits fixed on the server; a hashed account id as OpenAI's safety identifier), and stores nothing.

### 5. Proactivity

- **Spoken:** only alerts the user configured, delivered when the user is idle (already the rule).
- **Everything else:** a visual suggestion in the app or notch at a boundary, such as a finished turn, the app opening, or an upcoming event. Accept and dismiss are recorded per category, and a category the user keeps dismissing stops.
- **Ambient capture:** if added later (a Dayflow-style local timeline), it is opt-in and local, skips the model while the user is idle, batches frames into one contact sheet per interval, and masks secrets and private windows before anything is stored.

### 6. Security

- The permission kernel, receipts and the rule that memory never authorizes anything are unchanged. Calshot's model is stricter than every agent reviewed.
- Calendar text, invites, friends' calendars and screen text stay labelled untrusted data. Injection strings belong in the fixtures.
- Screen-derived knowledge is local-only and needs repeat evidence, as described above.

## Fixtures that guard quality

These are the minimum fixtures, from the review's "what would change this recommendation":
1. A preference that changes: the new value is current, the old one is history, and the old one is not re-learned by inference.
2. A fact the user told Calshot to forget never returns.
3. An early tool result in a long loop is still available at step eight.
4. A sentence that arrives while an earlier one is still speaking plays after it, in order.
5. No unprompted speech while the user or Calshot is talking.

Plus: an old but still-true conversation note is found by relevance long after it falls out of the recent window.

## Roadmap

| Phase | Work | State |
| --- | --- | --- |
| 1 | Voice queueing and speaking style; typed run metrics; memory validity and history; long-lived notes found by relevance; screen-inference evidence rule; typed schedule preload; voice sends an unchanged screen as one line; one typed learning pass per burst; fixtures | Done 2026-11-18 |
| 2 | Voice rebuilt as ears (live transcription), one brain (the agent, append-only and cached) and mouth (sentence speech), with Calshot's voice server; Realtime and GPT-Live removed | Built 2026-11-19; needs the hardware checks below |
| 3 | Visual proactive suggestions at boundaries with accept/dismiss learning | Planned |
| 4 | Optional local ambient timeline (idle bypass, contact sheets, redaction) | Exploring |

Not adopted, on the evidence:
- **A rolling model summary of the chat.** The window plus notes and search covers it, and a summary risks the ACE collapse.
- **Clearing tool results in the middle of a run.** It would break the prompt cache inside the run.
- **An embedding service or graph database.** Measure keyword misses on real questions first.
- **Lower reasoning effort or parallel tool calls for typed requests.** Not until the run metrics and fixtures show they keep quality. Voice uses low effort because the spoken answer is short and latency dominates; its run metrics are logged with outcome "voice …".

### Phase 2: checks on real hardware

1. Time from release to the first audible word, for an agenda question and for a change.
2. No self-interruption, and no stuck "speaking" after the reply.
3. Talking over a reply, and a correction while a request runs ("Friday… no, Thursday").
4. Undo by voice, and a review opened by voice.
5. English and Persian in one session.
6. The daily allowance message, and a lost connection mid-hold.
7. `AgentRuns.jsonl` shows cached input on the second and later turns of a session.

Known limits: the Ultrafast tier and WebSocket mode are not documented for ChatGPT plan tokens, so the tier is requested and dropped if the plan rejects it, and requests use HTTP streaming. Listening and speech go to Google through Calshot; the agent's requests go to the user's AI service as before.

## Sources

- Chroma, Context Rot (2025-07): https://www.trychroma.com/research/context-rot
- ACE, Agentic Context Engineering (ICLR 2026): https://arxiv.org/html/2510.04618v2
- Manus, Context Engineering for AI Agents (2025-07): https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus
- Anthropic, Effective context engineering for AI agents (2025-09): https://www.anthropic.com/research/effective-context-engineering-for-ai-agents
- Anthropic, Managing context on the Claude Developer Platform: https://claude.com/resources/articles/context-management
- OpenAI, Unrolling the Codex agent loop (2026-01): https://openai.com/index/unrolling-the-codex-agent-loop/
- Zep temporal knowledge graph: https://arxiv.org/abs/2501.13956 · Graphiti: https://github.com/getzep/graphiti
- Mem0: https://github.com/mem0ai/mem0 · Letta: https://github.com/letta-ai/letta · OpenClaw: https://github.com/openclaw/openclaw
- Google live transcription (2026-11-19): https://aistudio.google.com/docs/live-api/live-transcribe · ephemeral tokens: https://aistudio.google.com/docs/live-api/ephemeral-tokens · speech generation: https://aistudio.google.com/docs/speech-generation
- OpenAI Ultrafast mode: https://developers.openai.com/api/docs/guides/ultrafast-mode · prompt caching: https://developers.openai.com/api/docs/guides/prompt-caching · plan usage limits: https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
- HeyClicky 1.1.3 architecture notes: Design/Research/HeyClicky-1.1.3
- OpenAI GPT-Live delegation (the engine this replaced): https://developers.openai.com/api/docs/guides/live-delegation · sessions: https://developers.openai.com/api/docs/guides/live-conversations · costs: https://developers.openai.com/api/docs/guides/voice-latency-cost
- OpenAI gpt-realtime (2025-08): https://openai.com/index/introducing-gpt-realtime/
- Proactive timing studies: https://arxiv.org/html/2602.00880v1 · https://dl.acm.org/doi/full/10.1145/3742413.3789148
- Clicky: https://github.com/farzaa/clicky · OpenMausBot: https://github.com/milind-soni/OpenMausBot · Dayflow: https://github.com/JerryZLiu/dayflow · Coast: https://coast.app/
