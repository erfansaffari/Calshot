import { useEffect, useState } from "react";
import { ArrowUp, Check, ExternalLink, ScanLine, Square, X } from "lucide-react";
import Markdown from "react-markdown";
import { command, useAppState } from "./bridge";
import { Question } from "./components/Question";
import { Review } from "./components/Review";
import { InlineError, Spinner } from "./components/ui";

/** Small by default. Questions, edits and approvals share the native task's state. */
export default function NotchApp() {
  const state = useAppState();
  const [text, setText] = useState("");
  const [review, setReview] = useState(false);
  const [conversation, setConversation] = useState(false);
  const [source, setSource] = useState(false);
  const [error, setError] = useState("");
  const [sending, setSending] = useState(false);
  const rows = state.proposals.filter(p => p.inScope && !p.isFinished);
  const selected = rows.filter(p => p.isSelected);
  const busy = state.running || state.saving || state.isRecognizing || state.isCapturing;
  const working = busy && !state.question && !state.waitingApproval;
  const captured = Boolean(state.imageURL) && !state.messages.length && !rows.length;
  const finished = state.proposals.filter(p => p.isFinished && p.receipt);
  const destination = state.calendars.find(c => c.id === state.selectedCalendarID);
  const taskNotice = !busy && !captured && !state.summary ? state.status || (state.agentStatus?.includes("Connect ChatGPT") ? state.agentStatus : undefined) : undefined;
  const detail = Boolean(taskNotice || state.question || review || conversation || source || error || state.agentError || state.screenPermissionNeeded || state.notice);
  // Only clean, selected creates get a one-click shortcut. Other operations need visible review.
  const quickApprove = rows.length > 0 && rows.every(p => p.operation === "create" && p.isSelected && p.isApprovable && p.state !== "failed");
  const run = async (action: string, extra: Record<string, unknown> = {}) => {
    setError("");
    try { await command({ action, ...extra }); }
    catch (e) { setError((e as Error).message); }
  };
  useEffect(() => {
    document.documentElement.dataset.surface = "notch";
    document.documentElement.dataset.appearance = state.settings.appearance || "system";
  }, [state.settings.appearance]);
  useEffect(() => {
    const frame = requestAnimationFrame(() => {
      const children = [...(document.querySelector(".notch-details")?.children || [])].filter(e => e.getBoundingClientRect().height > 0);
      const contentHeight = children.length ? children[children.length - 1].getBoundingClientRect().bottom - children[0].getBoundingClientRect().top + 98 : 200;
      void command({ action: "notchLayout", detail, height: review ? 490 : Math.max(200, Math.min(490, Math.ceil(contentHeight))) }).catch(() => {});
    });
    return () => cancelAnimationFrame(frame);
  }, [detail, review, state.question?.id, state.messages.length, state.summary, error, state.agentError]);
  useEffect(() => { setText(""); setReview(false); setConversation(false); setSource(false); setError(""); }, [state.captureID]);
  useEffect(() => {
    const reset = () => { setReview(false); setConversation(false); setSource(false); };
    window.addEventListener("calshot:notch-collapsed", reset);
    return () => window.removeEventListener("calshot:notch-collapsed", reset);
  }, []);
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      if (e.metaKey && e.key === ".") { e.preventDefault(); void run("stop"); }
      if (e.key === "Escape" && !document.querySelector('[role="dialog"]')) {
        e.preventDefault();
        if (review || conversation || source) { setReview(false); setConversation(false); setSource(false); }
        else void run("collapseNotch");
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [review, conversation, source]);
  const submit = async () => {
    const message = text.trim() || (captured ? "Add the events visible in this screenshot to my calendar. Ask about unclear details before preparing changes." : "");
    if (!message || busy || sending) return;
    setSending(true); setError("");
    try { await command({ action: "send", text: message }); setText(""); setConversation(false); }
    catch (e) { setError((e as Error).message); }
    finally { setSending(false); }
  };
  return <div className="notch-shell">
    <div className="notch-bar">
      {working ? <>
        <Spinner /><span className="notch-label" role="status">{state.streaming || state.agentStatus || (state.isRecognizing ? "Reading screenshot" : state.saving ? "Saving changes" : "Working…")}</span>
        <button className="button secondary" onClick={() => void run("stop")}><Square size={11} /> Stop</button>
      </> : rows.length && !state.question ? <>
        <span className="notch-label">{rows.length} {rows.length === 1 ? "event" : "events"}{rows.every(p => p.operation === "create") && destination ? " → " + destination.title : " to review"}</span>
        <button className="button secondary" aria-expanded={review} onClick={() => setReview(!review)}>{review ? "Hide review" : "Review"}</button>
        {quickApprove && <button className="button primary" disabled={!state.canApprove || sending || state.checking} onClick={() => void run("approve", { token: state.approvalToken })}>{state.checking ? "Checking…" : "Add all"}</button>}
      </> : state.question ? <>
        <span className="notch-label">A quick question</span>
        <button className="text-button" onClick={() => void run("stop")}>Stop task</button>
      </> : <>
        {captured ? <button className="notch-thumb" aria-label="View captured screenshot" onClick={() => setSource(!source)}><img src={state.imageURL} alt="Captured screenshot" /></button> : <button className="button primary" disabled={busy || sending} onClick={() => void run("capture")}><ScanLine size={15} /> Capture</button>}
        <form className="notch-input" onSubmit={e => { e.preventDefault(); void submit(); }}>
          <input aria-label={captured ? "Screenshot instructions" : "Ask Calshot"} placeholder={captured ? "Anything to add? (optional)" : "Ask… “what’s on Friday?”"} value={text} maxLength={8000} onChange={e => setText(e.target.value)} disabled={busy || sending || !state.ready} />
          {(text.trim() || captured) && <button className={captured ? "button primary" : "icon-button"} disabled={sending || !state.ready} aria-label={captured ? "Add to calendar" : "Send message"}>{captured ? "Add to calendar" : <ArrowUp size={16} />}</button>}
        </form>
      </>}
      <button className="icon-button notch-popout" aria-label="Open full app" title="Open full app" onClick={() => void run("openWorkspace")}><ExternalLink size={15} /></button>
    </div>
    {detail && <div className="notch-details">
      <div className="notch-detail-heading"><span>{state.question ? "Your answer stays in this task" : review ? "Review changes" : source ? "Captured screenshot" : "Calendar conversation"}</span><button className="icon-button" aria-label="Hide details" onClick={() => { if (state.question) void run("collapseNotch"); else { setReview(false); setConversation(false); setSource(false); } }}><X size={14} /></button></div>
      <InlineError message={error || state.notice} />
      {taskNotice && !state.screenPermissionNeeded && <p role="status">{taskNotice}</p>}
      <InlineError message={state.agentError}>{state.canRetry && <button className="text-button" onClick={() => void run("retryAgent")}>Try again</button>}</InlineError>
      {state.screenPermissionNeeded && <InlineError message={state.status || "Allow Screen Recording to capture your screen."}><button className="text-button" onClick={() => void run("screenSettings")}>Open Screen Recording settings</button></InlineError>}
      {state.question ? <Question key={state.question.id} question={state.question} /> : review ? <Review state={state} /> : source ? <img className="notch-source" src={state.imageURL} alt="Source screenshot" /> : conversation ? <div className="notch-conversation" aria-label="Calendar conversation">{state.messages.filter(m => m.content && (m.role === "user" || m.role === "assistant") && !m.toolName).map((m, i) => <div key={i} className={"notch-message " + m.role}><small>{m.role === "user" ? "You" : "Calshot"}</small><Markdown>{m.content || ""}</Markdown></div>)}{state.summary && !state.messages.some(m => m.content === state.summary) && <div className="notch-message assistant"><Markdown>{state.summary}</Markdown></div>}{!state.running && !state.messages.length && state.agentStatus && <p>{state.agentStatus}</p>}</div> : null}
      {!!rows.length && !state.question && <form className="notch-followup" onSubmit={e => { e.preventDefault(); void submit(); }}><input aria-label="Follow-up message" placeholder={busy ? "Approve or skip these changes to continue" : "Ask a follow-up…"} value={text} maxLength={8000} disabled={busy || sending} onChange={e => setText(e.target.value)} /><button className="button primary" disabled={busy || sending || !text.trim()} aria-label="Send follow-up"><ArrowUp size={14} /></button></form>}
      {!state.question && !busy && <div className="notch-footer"><button className="text-button" onClick={() => void run("newTask")}>New task</button>{state.imageURL && <button className="text-button" onClick={() => { setSource(!source); setReview(false); }}>View screenshot</button>}</div>}
    </div>}
    {!detail && !working && (finished.length > 0 || state.messages.length > 0) && <button className="notch-reopen" onClick={() => setConversation(true)}>{finished.length ? <><Check size={12} /> {finished.length} saved · View conversation</> : "View conversation"}</button>}
  </div>;
}
