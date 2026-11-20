# Agents, jobs, and computer use

## From a voice turn to a long-running job

Voice is the interaction surface. The job is the durable unit of work. The installed build has a distinct job store, run history, handoff UI, agent harness and output presentation.

| Stage | Evidence |
| --- | --- |
| Scope the work | A handoff can carry the agreed task context. The 1.1.3 notes say it sends the details settled in conversation, including when the user approves a plan by voice. |
| Start or continue | `ClickyJobMessageRoute` can target the current thread or begin a new run that follows an earlier thread. `AgentHarnessTurn` carries separate harness and app thread IDs, turn ID, first-turn state, text, attachments, workspace and model. |
| Run | `AgentHarnessRunnerProcess` holds a process, stdin pipe and an endpoint. The app packages a native `clicky-harness` helper. The API types distinguish a bundled launch and a Node launch, and a runtime selection for Mac or cloud. |
| Stream | `AgentHarnessEvent` represents commentary, thinking, plan, tool start/finish, search, answer deltas, program batches, note preview/save, compaction and completion. A relay stores the latest commentary per job and schedules a flush. |
| Ask for the user | The job can enter a waiting step with instructions and a page. A watcher can recognize the expected page transition. The rail distinguishes queued, working, needs-you, done, failed and stopped. |
| Close or revisit | The job stores outcomes, summary, reply, artifact entries, a working folder and past runs. A report object can show a heads-up, play a chime or speak. The vendor documents stop, steering and following up from the agent chat. |

The local metadata establishes structures and a shipped helper, along with choices named Codex, Pi and H1. It does not establish which harness or place runs by default. `AgentHarnessModel` exposes Standard, Astra, Sol, Terra, Luna and Claude family names. The separate model catalog lists options but does not resolve how a job maps to a provider. [Voice and model evidence](02-voice-and-models.md) · [Official release notes](https://www.heyclicky.com/changelog)

## Workspace, tools, and continuity

- The turn context carries instructions, managed and user skill paths, MCP server descriptors, model, note path and hints about planning and writing. This is an explicit boundary between the foreground assistant and the execution environment.
- The bundle includes job guidance that treats a workspace as continuity across runs: earlier artifacts, a per-job record and an optional memory file. It also asks the job to keep a user-facing plan current. This is evidence for the agent's intended behavior. Runtime lease renewal, cancellation delivery and workspace constraints were not observed.
- Connectors are another execution surface. Bundled skill folders cover examples such as Gmail, Outlook, Google Tasks, Google Docs, Linear and Teams. The settings and associated account metadata distinguish connection and reconnection state.
- Jobs can be scheduled and later resumed as the same job according to 1.1.3 release notes. The type metadata contains a routine plan with create/update/pause/resume/stop operations. The metadata does not establish where scheduling is performed. [Bundled job instructions](/Applications/HeyClicky.app/Contents/Resources/ClickyModelInstructions.md) · [Official release notes](https://www.heyclicky.com/changelog)

## Computer use has distinct surfaces

| Surface | Evidence and boundary |
| --- | --- |
| **Guided screen help** | The assistant presents a pointer, highlight or step and the user acts. `ScreenDrawingTargetSnapper`, native pointer-action records, foreground-app state and guided follow-up state support screen-anchored guidance. The vendor says it checks the screen again before suggesting the next step. |
| **Drive the Mac** | `ClickyTakeOverController` has offered, driving and idle phases, a consent card, target application, step capture, input monitor, loop task, action log and termination reasons. It distinguishes a completed drive, user takeover, safety stop, missing screen and failure. The executable imports accessibility lookup/action APIs and CoreGraphics input-event APIs. |
| **Operate Chrome** | The bundle contains `ClickyBrowserHost`, a browser setup UI and a browser skill. `ClickyBrowserBridge` has profile/session/task binding, peers, command and grant state, pending replies, per-task timeouts, connection recovery, upload approval and task-specific cleanup. Product docs describe an extension in the signed-in browser profile, with task tabs grouped separately. |
| **Use a connected API or public web** | The bundled guidance sends connected-account work through the connected app and public information retrieval through public web. This can avoid touching the user's foreground browser. |

For native Drive, `OneBrainClient.ComputerCall` carries actions and pending safety checks, and the notch state exposes consent callbacks and visible drive state. The vendor describes asking before taking control and handing it back on user input or Escape. The type and import evidence does not prove how consent is enforced, how a model chooses actions, or which Accessibility or event method is used for each action. No actions were executed.

For Chrome, the bundled guidance describes outcome verification, retaining result tabs when needed, stopping when the user revokes access, and asking before sensitive final actions when they lack authorization. The 1.1.3 release specifically describes a site-scoped confirmation for sending a local file unless an explicit setting allows it. These are documented expectations. The study did not test enforcement or inspect the user's browser data. [Bundled browser skill](/Applications/HeyClicky.app/Contents/Resources/ClickyBundledSkills/clicky-browser/SKILL.md) · [Official release notes](https://www.heyclicky.com/changelog)
