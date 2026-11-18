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

### 4. Voice: one brain, a conversational front end

The current Realtime voice model receives the whole typed prompt, picks tools itself, and produces every word. That makes it verbose and gives it a second, weaker copy of the agent's judgment.

- **Done now:** audio from a reply that follows a tool call now waits behind the words still playing, instead of cutting them off. On barge-in, only the audio the user actually heard is kept in the model's memory. A short speaking-style block leads the voice prompt.
- **Next: GPT-Live with client delegation.** GPT-Live (`gpt-live-1`, $0.05/minute) listens and speaks. When work is needed it delegates, and Calshot's own typed agent does the work with the same prompt, tools, permissions, memory and receipts. Results return as `session.commentary.append` (spoken, paraphrased, without cutting off current speech), and background facts as `session.thinking.append` (not spoken). This gives typed and voice the same intelligence, puts the permission kernel on one path, removes the long prompt from the audio model, and fixes interruptions structurally. The screen goes to the backend model, because GPT-Live does not take images. It ships behind a Voice setting until it passes the voice fixtures on real hardware.

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
4. A tool result that arrives while voice is still speaking queues behind it instead of cutting it off.
5. No unprompted speech while the user or Calshot is talking.

Plus: an old but still-true conversation note is found by relevance long after it falls out of the recent window.

## Roadmap

| Phase | Work | State |
| --- | --- | --- |
| 1 | Voice queueing and speaking style; typed run metrics; memory validity and history; long-lived notes found by relevance; screen-inference evidence rule; typed schedule preload; voice sends an unchanged screen as one line; one typed learning pass per burst; fixtures | Done 2026-11-18 |
| 2 | GPT-Live voice engine with client delegation to the typed agent, behind a Voice setting | Specified below; needs live hardware sessions |
| 3 | Visual proactive suggestions at boundaries with accept/dismiss learning | Planned |
| 4 | Optional local ambient timeline (idle bypass, contact sheets, redaction) | Exploring |

Not adopted, on the evidence:
- **A rolling model summary of the chat.** The window plus notes and search covers it, and a summary risks the ACE collapse.
- **Clearing tool results in the middle of a run.** It would break the prompt cache inside the run.
- **An embedding service or graph database.** Measure keyword misses on real questions first.
- **Lower reasoning effort or parallel tool calls.** Not until the run metrics and fixtures show they keep quality.

### Phase 2 specification: GPT-Live voice

These are protocol facts from OpenAI's GPT-Live guides and WebSocket reference, read 2026-11-18.

- **Connection.** `wss://api.openai.com/v1/live/sessions` with the API key. The first message is `session.start` with `model: "gpt-live-1"`, short conversation instructions, `audio.format` `{type: "audio/pcm", rate: 24000}` (the same as today's capture and playback), a voice, and `delegation: {type: "client", acknowledgement_delay_ms: 800}`. Wait for `session.started` before sending audio.
- **Audio.** Send `session.input_audio.append` with base64 PCM16. Receive `session.output_audio.delta` (with `start_ms`/`end_ms`) and queue it. There is no output-done or interruption event over WebSocket, so the app's player owns playback state.
- **Push-to-talk.** `session.input_audio.unmute` while the key is held and `session.input_audio.mute` on release. Muted input is silence to the model, so it takes its turn at the pause. Holding the key while Calshot speaks flushes local playback, as barge-in does now. Speakers are never captured while the key is up, which keeps echo out without echo cancellation.
- **Delegation.**
  1. `session.delegation.created` carries only an id. Calshot builds the request from `session.input_transcript.delta`/`session.output_transcript.delta` and its own state.
  2. It immediately sends an empty `session.thinking.append` with that id to cancel the automatic acknowledgment, when a short "checking" is not wanted.
  3. It runs the typed `CalendarAgent` with the same grants, reviews and receipts.
  4. It returns verified facts with `session.commentary.append` (spoken and paraphrased, at most 500 tokens), or `session.thinking.append` for quiet context.
  5. A result for a request the user has since corrected is dropped.
- **Screen.** GPT-Live takes no images. Screen text and drawn marks go to the backend request; the image goes only to the backend model.
- **Context.** `session.input` seeds recent turns as text at start. GPT-Live summarizes its own long sessions (128k window; a replacement engine gets 8,192 tokens). Calshot's records remain the source of truth.
- **Cost.** $0.05 per voice minute, billed per second, plus backend tokens on the selected typed route. The monthly voice cap counts minutes.
- **Before it becomes the default,** these must pass on real hardware against today's engine:
  1. time to the first useful spoken answer;
  2. no self-interruption;
  3. a question asked while a tool runs;
  4. a correction that arrives mid-task;
  5. Undo by voice;
  6. a review opened by voice.

## Sources

- Chroma, Context Rot (2025-07): https://www.trychroma.com/research/context-rot
- ACE, Agentic Context Engineering (ICLR 2026): https://arxiv.org/html/2510.04618v2
- Manus, Context Engineering for AI Agents (2025-07): https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus
- Anthropic, Effective context engineering for AI agents (2025-09): https://www.anthropic.com/research/effective-context-engineering-for-ai-agents
- Anthropic, Managing context on the Claude Developer Platform: https://claude.com/resources/articles/context-management
- OpenAI, Unrolling the Codex agent loop (2026-01): https://openai.com/index/unrolling-the-codex-agent-loop/
- Zep temporal knowledge graph: https://arxiv.org/abs/2501.13956 · Graphiti: https://github.com/getzep/graphiti
- Mem0: https://github.com/mem0ai/mem0 · Letta: https://github.com/letta-ai/letta · OpenClaw: https://github.com/openclaw/openclaw
- OpenAI GPT-Live delegation: https://developers.openai.com/api/docs/guides/live-delegation · sessions: https://developers.openai.com/api/docs/guides/live-conversations · costs: https://developers.openai.com/api/docs/guides/voice-latency-cost
- OpenAI gpt-realtime (2025-08): https://openai.com/index/introducing-gpt-realtime/
- Proactive timing studies: https://arxiv.org/html/2602.00880v1 · https://dl.acm.org/doi/full/10.1145/3742413.3789148
- Clicky: https://github.com/farzaa/clicky · OpenMausBot: https://github.com/milind-soni/OpenMausBot · Dayflow: https://github.com/JerryZLiu/dayflow · Coast: https://coast.app/
