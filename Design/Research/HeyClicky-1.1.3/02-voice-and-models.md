# Voice, model routing, and audio

## There are several distinct paths

| Role | Evidence in 1.1.3 | What remains open |
| --- | --- | --- |
| OneBrain interaction | `OneBrainVoice` stores session context, screen context, a transcriber, orchestration state and accumulated drawing code. `OneBrainClient.Reply` includes text-to-speak, code, tool/computer calls, model identifier, latency, usage, cost and turn token. | Which route and model were selected for any live turn |
| Speech recognition | `OneBrainGeminiTranscriber` has a token proxy, WebSocket, PCM resampling, pending audio, interim/final segments and warm-session timing. A separate Apple Speech provider exists. | Exact Gemini input model and when Apple Speech is used |
| Dedicated speech output | `GeminiMouthProtocol` and a per-line ledger hold verbatim lines, audio arrival, transcript and completion/discard status. The binary contains `gemini-3.8-flash-lite-tts`. | Whether that exact ID was selected and whether it served every available voice |
| Direct Realtime voice | `RealtimeVoiceClient` and `RealtimeToolDispatcher` support session setup, streaming audio, transcription, playback accounting and tool calls. The provider enum includes OpenAI and Gemini. Binary strings include `gpt-realtime`, `gpt-realtime-2.1` and `gpt-realtime-2.1-mini`. | Which models are defaults, fallback variants, experiments or retired options |
| Dictation | `ClickyDictationController` tracks its own warm connection, focused app/field context, partial transcript and cleanup timing. `DictationTranscriptionClient` has distinct transcription and cleanup configuration fields. | Exact cleanup model and active provider selection |

**The installed build does not identify a single model for “everything.”** Names appear at three levels: interaction choice, actual reply model identifier, and a separate catalog for job models. The OneBrain choice enum contains Sol speed/effort variants, Terra, Claude Haiku/Sonnet/Opus and DeepSeek options. Adjacent evidence in the binary includes GPT-6.1 Sol variant strings, `gpt-6.1-terra-fast-medium` and Claude Fable/Haiku/Sonnet/Opus IDs. These independent static observations are insufficient to match every enum case to the exact network ID. The worker can also make a selection that differs from what ships locally.

The packaged **Codex job catalog** includes GPT-6 Luna/Sol/Astra, GPT-6.1 Sol, GPT-5.6 Sol/Terra/Luna and earlier entries. Some entries are hidden and some expose fast tiers. A catalog default is the reasoning effort for that entry. It does not establish the job default. [Packaged model catalog](/Applications/HeyClicky.app/Contents/Resources/ClickyCodexModelCatalog.json)

Older release notes name GPT Realtime 2.1 for an earlier direct voice release and Claude Fable 5 as an older default. Those statements do not set the OneBrain default in 1.1.3. [Official release notes](https://www.heyclicky.com/changelog)

## Turn flow supported by the metadata

1. **Shortcut and input.** The main coordinator tracks push-to-talk start/release and Escape. The direct Realtime path also has a server voice activity mode and explicit always-on barge-in state. Separate microphone acquisition, input signal and permission state support more specific failure feedback.
2. **Prepare context while the user speaks.** OneBrain has prewarm and ready state. It also holds a page read that can start on key-down, the selected screen/annotation context and saved session state. The state suggests parallel preparation. It does not establish which bytes are submitted on every turn.
3. **Resolve transcript and interaction.** The Gemini transcriber can buffer PCM through readiness and report partial speech. A waiter resolves the transcript alongside the conversation request lifecycle. `OneBrainClient.Reply` can represent a mixture of spoken sentence, drawing code, tool calls and desktop actions.
4. **Present incrementally.** The drawing parser accepts complete prefixes of a streamed program. The speech side exposes a line ledger and audio progress. Voice and drawing use these events to keep presentation in order. See [drawing and narration](04-drawing-3d-and-narration.md).
5. **Handle interruption and retain continuity.** Session state includes compaction generation, token counts, a saved-session lookup, prior drawing code and context signatures. The client specifies a compact result with a note and indices describing which prior items to keep or drop. The exact compaction threshold and storage policy were not established.

## Audio reliability details

- The app links both AVCaptureSession and AVAudioEngine. The metadata identifies distinct microphone capture, duplex audio, standalone player and microphone test components. Input/output route listeners, a delayed rebuild path and playback generation counters are present.
- It records delivered and non-silent microphone chunks independently. Recovery state includes a duplex capture silence watchdog, a pending duplex path, input-device failover and delayed Bluetooth teardown. These fields establish the existence of those mechanisms. The selection thresholds and order are unverified.
- `OneBrainTurnTiming.Marks` exposes release, transcript, request start, headers and first token timestamps, plus request body size and compression flags. The transcriber separately tracks warm/cold, token ready, first text and final receipt. The Realtime client tracks first enqueued audio, frame-count baselines and response-specific playback state. This is enough to split user-perceived latency into input, transcript, reasoning and audible output.
