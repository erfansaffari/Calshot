import { useEffect, useRef, useState } from "react";
import {
  CalendarDays,
  MessageSquare,
  History,
  Settings,
  ScanLine,
  Plus,
  PanelRight,
  ImagePlus,
  ArrowUp,
  Paperclip,
  Square,
  Check,
  Sparkles,
  Image as ImageIcon,
  X,
  ShieldCheck,
} from "lucide-react";
import Markdown from "react-markdown";
import { command, useAppState } from "./bridge";
import type { AppState, Page } from "./types";
import { Badge, Empty, InlineError, Modal, Spinner } from "./components/ui";
import { Review } from "./components/Review";
import { TaskChangeReview, TaskOutcomeCard } from "./components/TaskChangeReview";
import { Question } from "./components/Question";
import { HomeTasks } from "./components/HomeTasks";
import { AccountScreen } from "./views/AccountScreen";
import { TasksPage } from "./views/TasksPage";
import { CalendarPage } from "./views/CalendarPage";
import { Sidebar } from "./components/Sidebar";
import { HistoryPage, SettingsPage } from "./views/Pages";
function App() {
  const state = useAppState(),
    [source, setSource] = useState(false),
    [historyPicker, setHistoryPicker] = useState(false),
    [error, setError] = useState(""),
    [text, setText] = useState(""),
    [sending, setSending] = useState(false);
  useEffect(() => {
    document.documentElement.dataset.appearance =
      state.settings.appearance || "system";
  }, [state.settings.appearance]);
  const bottom = useRef<HTMLDivElement>(null),
    nearBottom = useRef(true),
    composer = useRef<HTMLTextAreaElement>(null);
  const hasTask = Boolean(
      state.messages.length ||
      state.imageURL ||
      state.proposals.length ||
      state.running ||
      state.agentError ||
      state.taskReview ||
      state.taskOutcome ||
      state.status,
    ),
    assistant = state.page === "chat" || state.page === "capture";
  const run = async (action: string, extra: Record<string, unknown> = {}) => {
    setError("");
    try {
      await command({ action, ...extra });
    } catch (e) {
      setError((e as Error).message);
    }
  };
  useEffect(() => {
    if (!nearBottom.current) return;
    const frame = requestAnimationFrame(() => {
      const timeline = bottom.current?.closest(".timeline");
      if (timeline) timeline.scrollTop = timeline.scrollHeight;
    });
    return () => cancelAnimationFrame(frame);
  }, [
    state.messages.length,
    state.streaming,
    state.question?.id,
    state.waitingApproval,
    state.taskReview?.id,
    state.taskOutcome?.id,
    state.proposals.length,
    source,
    state.ready,
  ]);
  useEffect(() => {
    setText("");
    setError("");
  }, [state.captureID]);
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.metaKey && event.key === ".") {
        event.preventDefault();
        void run("stop");
      }
      if (
        event.metaKey &&
        event.key === "Enter" &&
        assistant &&
        state.canApprove &&
        !document.querySelector('[role="dialog"]')
      ) {
        event.preventDefault();
        void run("approve", { token: state.approvalToken });
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [state.approvalToken, state.canApprove, assistant]);
  useEffect(() => {
    setSource(Boolean(state.imageURL) && window.innerWidth > 1120);
  }, [state.imageURL]);
  useEffect(() => {
    const resize = () => {
      if (window.innerWidth <= 1120) setSource(false);
      if (nearBottom.current)
        requestAnimationFrame(() => {
          const timeline = bottom.current?.closest(".timeline");
          if (timeline) timeline.scrollTop = timeline.scrollHeight;
        });
    };
    window.addEventListener("resize", resize);
    return () => window.removeEventListener("resize", resize);
  }, []);
  const submit = async () => {
    if (!text.trim() || sending) return;
    setSending(true);
    setError("");
    try {
      await command({
        action: "send",
        text: text.trim(),
        questionID: state.question?.id,
      });
      setText("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSending(false);
    }
  };
  if (!state.ready) return <Startup />;
  if (state.auth?.required && (!state.auth.signedIn || !state.auth.onboarded || state.auth.phase === "passwordRecovery")) return <AccountScreen state={state} />;
  return (
    <div className={"app" + (state.page === "calendars" ? " calendar-workspace" : "")}>
      <Sidebar state={state} onAction={run} />
      <main className="workspace">
        {assistant ? (
          <>
            <header className="workspace-header">
              <div className="heading">
                <h1 className="truncate">
                  {hasTask
                    ? (
                        state.messages.find((m) => m.role === "user")
                          ?.content || "Screenshot task"
                      ).slice(0, 90)
                    : "Assistant"}
                </h1>
                <small>
                  {hasTask
                    ? state.imageURL
                      ? "From a screenshot"
                      : "Your calendar assistant"
                    : "Your calendars, a little easier"}
                </small>
              </div>
              <button
                className="button secondary"
                disabled={
                  state.running ||
                  state.saving ||
                  state.isCapturing ||
                  state.isRecognizing
                }
                onClick={() => void run("newTask")}
              >
                <Plus size={13} />
                New task
              </button>
              {state.imageURL && (
                <button
                  className="icon-button"
                  aria-label={source ? "Hide source" : "Show source"}
                  aria-expanded={source}
                  onClick={() => setSource(!source)}
                >
                  <PanelRight size={16} />
                </button>
              )}
            </header>
            {state.notice && (
              <div className="notice" role="status">
                <p>{state.notice}</p>
                <button
                  className="icon-button"
                  aria-label="Dismiss notice"
                  onClick={() => void run("dismissNotice")}
                >
                  <X size={14} />
                </button>
              </div>
            )}
            <div className="content-columns">
              <section
                className="conversation"
                aria-label="Calendar conversation"
              >
                {!hasTask ? (
                  <div className="timeline">
                    <div className="home">
                      <div className="home-logo">
                        <Sparkles size={23} />
                      </div>
                      <h1>What should go on your calendar?</h1>
                      <p>Capture something on your screen, or just ask.</p>
                      <div className="capture-options">
                        <button
                          className="capture-tile"
                          onClick={() => void run("capture")}
                        >
                          <ScanLine size={22} />
                          <strong>Capture screen</strong>
                          <small>
                            Drag over a syllabus, roster or poster ·{" "}
                            {state.shortcut}
                          </small>
                        </button>
                        <button
                          className="capture-tile"
                          onClick={() => setHistoryPicker(true)}
                        >
                          <ImagePlus size={22} />
                          <strong>Use a screenshot</strong>
                          <small>Pick a capture from your History</small>
                        </button>
                      </div>
                      <HomeTasks state={state} onCommand={command} />
                      <p className="section-label">Ask Calshot</p>
                      <div className="suggestions">
                        {[
                          "What do I have tomorrow?",
                          "Move my weekend shifts to Work",
                          "Help me add my course deadlines",
                        ].map((prompt) => (
                          <button
                            key={prompt}
                            onClick={() => {
                              setText(prompt);
                              composer.current?.focus();
                            }}
                          >
                            {prompt}
                          </button>
                        ))}
                      </div>
                      <RecentScreenshots
                        state={state}
                        onSelect={(id) =>
                          void run("restoreMemory", { recordID: id })
                        }
                      />
                      {!state.calendars.length && (
                        <div
                          className="card settings-card"
                          style={{ marginTop: 20 }}
                        >
                          <h3>Let Calshot see your calendars</h3>
                          <p className="fine-print">
                            Use calendars already on this Mac or connect an
                            account. Calendar changes always need your approval.
                          </p>
                          <button
                            className="text-button"
                            onClick={() =>
                              void run("navigate", { page: "calendars" })
                            }
                          >
                            Connect calendars
                          </button>
                        </div>
                      )}
                    </div>
                  </div>
                ) : (
                  <div
                    className="timeline"
                    onScroll={(e) => {
                      const el = e.currentTarget;
                      nearBottom.current =
                        el.scrollHeight - el.scrollTop - el.clientHeight < 140;
                    }}
                  >
                    <div className="timeline-inner">
                      {state.messages
                        .filter(
                          (m) =>
                            m.content &&
                            (m.role === "user" || m.role === "assistant"),
                        )
                        .map((m, i) => (
                          <article className={"message " + m.role} key={i}>
                            {m.role === "user" ? (
                              m.content
                            ) : (
                              <Markdown>{m.content || ""}</Markdown>
                            )}
                          </article>
                        ))}
                      {state.running && state.streaming && (
                        <article className="message assistant">
                          <Markdown>{state.streaming}</Markdown>
                        </article>
                      )}
                      {state.agentStatus && (
                        <p className="step" role="status">
                          {state.running &&
                          !state.question &&
                          !state.taskReview &&
                          !state.waitingApproval ? (
                            <Spinner />
                          ) : (
                            <Check size={13} />
                          )}{" "}
                          {state.agentStatus}
                        </p>
                      )}
                      {state.question && (
                        <Question
                          key={state.question.id}
                          question={state.question}
                        />
                      )}
                      {state.taskReview && (
                        <TaskChangeReview key={state.taskReview.id} review={state.taskReview} />
                      )}
                      {state.taskOutcome && !state.taskReview && (
                        <TaskOutcomeCard key={state.taskOutcome.id} outcome={state.taskOutcome} />
                      )}
                      {(state.proposals.length > 0 || state.taskImport) && <Review state={state} />}
                      {state.summary &&
                        !state.running &&
                        !state.messages.some(
                          (m) =>
                            m.role === "assistant" &&
                            m.content === state.summary,
                        ) && (
                          <article className="message assistant">
                            <Markdown>{state.summary}</Markdown>
                          </article>
                        )}
                      {state.agentError && (
                        <InlineError message="Calshot couldn't finish this request.">
                          <details>
                            <summary>Details</summary>
                            <p>{state.agentError}</p>
                          </details>
                          {state.canRetry && (
                            <button
                              className="button secondary"
                              disabled={state.running || state.saving}
                              onClick={() => void run("retryAgent")}
                            >
                              Try again
                            </button>
                          )}
                          <button
                            className="button ghost"
                            onClick={() =>
                              void run("navigate", { page: "settings" })
                            }
                          >
                            AI settings
                          </button>
                        </InlineError>
                      )}
                      {state.status && (
                        <InlineError message={state.status}>
                          {state.screenPermissionNeeded && (
                            <button
                              className="button secondary"
                              onClick={() => void run("screenSettings")}
                            >
                              Open Screen Recording settings
                            </button>
                          )}
                        </InlineError>
                      )}
                      <div ref={bottom} />
                    </div>
                  </div>
                )}
                <div className="composer-area">
                  <InlineError message={error} />
                  <div className="composer-status" role="status">
                    <span>
                      {state.question
                        ? "Waiting for your answer — choose above or type below"
                        : state.taskReview
                          ? state.taskReview.phase === "applying"
                            ? "Saving the task change…"
                            : "Waiting for your review of the task change"
                          : state.waitingApproval
                          ? "Waiting for your approval"
                          : state.saving
                            ? "Saving approved changes…"
                            : state.isRecognizing
                              ? "Reading the screenshot…"
                              : state.running
                                ? "Calshot is working…"
                                : "Calendar changes need your approval"}
                    </span>
                    {(state.running || state.saving) && (
                      <button
                        className="text-button"
                        onClick={() => void run("stop")}
                      >
                        <Square size={10} /> Stop
                      </button>
                    )}
                  </div>
                  {state.imageURL && (
                    <div className="composer-context">
                      <ImageIcon size={12} /> Screenshot attached{" "}
                      <button
                        className="text-button"
                        onClick={() => setSource(!source)}
                      >
                        View source
                      </button>
                    </div>
                  )}
                  <form
                    className="composer"
                    onSubmit={(e) => {
                      e.preventDefault();
                      void submit();
                    }}
                  >
                    <textarea
                      ref={composer}
                      aria-label={
                        state.question ? "Answer Calshot" : "Message Calshot"
                      }
                      placeholder={
                        state.question
                          ? "Type your answer…"
                          : state.taskReview || state.waitingApproval
                            ? "Review the proposed changes above…"
                            : "Ask a question or tell Calshot what to do…"
                      }
                      value={text}
                      maxLength={8000}
                      rows={1}
                      disabled={
                        sending ||
                        state.saving ||
                        state.isCapturing ||
                        state.isRecognizing ||
                        (state.running && !state.question)
                      }
                      onChange={(e) => setText(e.target.value)}
                      onKeyDown={(e) => {
                        if (
                          e.key === "Enter" &&
                          !e.shiftKey &&
                          !e.nativeEvent.isComposing
                        ) {
                          e.preventDefault();
                          void submit();
                        }
                      }}
                    />
                    <button
                      type="button"
                      className="icon-button"
                      disabled={state.running || state.saving}
                      aria-label="Choose a screenshot from History"
                      onClick={() => setHistoryPicker(true)}
                    >
                      <Paperclip size={16} />
                    </button>
                    <button
                      type="button"
                      className="icon-button"
                      disabled={state.saving || state.isCapturing}
                      aria-label="Capture screenshot"
                      onClick={() => void run("capture")}
                    >
                      <ScanLine size={17} />
                    </button>
                    <button
                      className="primary"
                      aria-label="Send message"
                      disabled={
                        !text.trim() ||
                        sending ||
                        state.saving ||
                        state.isRecognizing ||
                        (state.running && !state.question)
                      }
                    >
                      {sending ? <Spinner /> : <ArrowUp size={19} />}
                    </button>
                  </form>
                </div>
              </section>
              {state.imageURL && source && (
                <aside className="source-panel is-open">
                  <div className="section-heading">
                    <h3>Source</h3>
                    <button
                      className="icon-button"
                      aria-label="Close source"
                      onClick={() => setSource(false)}
                    >
                      <X size={14} />
                    </button>
                  </div>
                  <img
                    className="source-image"
                    src={state.imageURL}
                    alt="Captured screenshot for the current task"
                  />
                  <p className="fine-print">
                    Only the captured area was read. Content above or below it
                    isn't included.
                  </p>
                  <details>
                    <summary>Show recognized text</summary>
                    <pre className="source-text">
                      {state.ocr ||
                        "Recognized text will appear when available."}
                    </pre>
                  </details>
                  <button
                    className="button secondary"
                    style={{ marginTop: 15 }}
                    disabled={state.saving || state.isCapturing}
                    onClick={() => void run("capture", { append: true })}
                  >
                    <Plus size={13} />
                    Add another screenshot
                  </button>
                </aside>
              )}
            </div>
          </>
        ) : state.page === "calendars" ? (
          <CalendarPage state={state} onCommand={command} />
        ) : state.page === "tasks" ? (
          <TasksPage state={state} onCommand={command} deadlineReview={<Review state={state} />} />
        ) : state.page === "library" ? (
          <HistoryPage state={state} />
        ) : (
          <SettingsPage state={state} />
        )}
      </main>
      {historyPicker && (
        <Modal
          title="Use a screenshot from History"
          onClose={() => setHistoryPicker(false)}
          wide
        >
          <p className="fine-print" style={{ marginBottom: 16 }}>
            Continue the task associated with this screenshot. Completed
            calendar changes are kept.
          </p>
          {state.memory.some((r) => r.imageURL) ? (
            <div className="attachment-picker">
              {state.memory
                .filter((r) => r.imageURL)
                .map((r) => (
                  <button
                    className="screenshot-tile"
                    key={r.id}
                    disabled={state.running || state.saving}
                    onClick={async () => {
                      await run("restoreMemory", { recordID: r.id });
                      setHistoryPicker(false);
                    }}
                  >
                    <img src={r.imageURL} alt="" />
                    <span className="truncate">{r.title}</span>
                  </button>
                ))}
            </div>
          ) : (
            <Empty icon={<ImageIcon size={25} />} title="No screenshots yet">
              Capture an area of your screen to get started.
            </Empty>
          )}
        </Modal>
      )}
      {!state.native && (
        <div className="preview-label">
          Design preview · fictional data · no calendar access
        </div>
      )}
    </div>
  );
}
function Startup() {
  const [expired, setExpired] = useState(false);
  useEffect(() => {
    const timer = setTimeout(() => setExpired(true), 12000);
    return () => clearTimeout(timer);
  }, []);
  return expired ? (
    <div className="empty" role="alert">
      <h2>Calshot couldn't connect to its native services</h2>
      <p>Reopen the app to reconnect. Completed calendar changes are kept.</p>
      <button
        className="button primary"
        onClick={() => window.location.reload()}
      >
        Reload interface
      </button>
    </div>
  ) : (
    <div className="loading">
      <Spinner />
      Opening Calshot…
    </div>
  );
}
function RecentScreenshots({
  state,
  onSelect,
}: {
  state: AppState;
  onSelect: (id: string) => void;
}) {
  const rows = state.memory.filter((r) => r.imageURL).slice(0, 5);
  return rows.length ? (
    <>
      <div className="section-heading">
        <h3>Recent screenshots</h3>
        <small>Click to continue</small>
      </div>
      <div className="recent-strip">
        {rows.map((r) => (
          <button
            className="screenshot-tile"
            key={r.id}
            onClick={() => onSelect(r.id)}
          >
            <img src={r.imageURL} alt="" />
            <span className="truncate">{r.title}</span>
          </button>
        ))}
      </div>
    </>
  ) : null;
}
export default App;
