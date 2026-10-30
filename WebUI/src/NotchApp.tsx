import { useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type PointerEvent as ReactPointerEvent } from "react";
import { ArrowUp, ChevronDown, ExternalLink, Eye, Mic, ScanLine, Square, X } from "lucide-react";
import { VoicePill } from "./components/VoicePill";
import { command, useAppState } from "./bridge";
import { Question } from "./components/Question";
import { Review } from "./components/Review";
import { TaskChangeReview, TaskOutcomeCard } from "./components/TaskChangeReview";
import { InlineError, Spinner } from "./components/ui";

/** Small by default. Questions, edits and approvals share the native task's state. */
export default function NotchApp() {
  const state = useAppState();
  const lastReturn = useRef(-Infinity);
  const [text, setText] = useState("");
  const [reviewRequested, setReview] = useState(true);
  const [sourceRequested, setSource] = useState(false);
  const [error, setError] = useState("");
  const [sending, setSending] = useState(false);
  const [dismissedOutcome, setDismissedOutcome] = useState("");
  const voice = state.voice;
  const compact = state.notchExpanded === false;
  const voiceRun = (action: string, extra: Record<string, unknown> = {}) => run(action, { token: voice?.token, ...extra });
  // Push-to-talk: press sends the current token; release is accepted after the press rotates it.
  const talkProps = {
    onPointerDown: (e: ReactPointerEvent<HTMLButtonElement>) => { if (e.button !== 0) return; e.currentTarget.setPointerCapture?.(e.pointerId); void voiceRun("voiceTalk", { pressed: true }); },
    onPointerUp: () => void run("voiceTalk", { pressed: false }),
    onPointerCancel: () => void run("voiceTalk", { pressed: false }),
    onKeyDown: (e: ReactKeyboardEvent) => { if ((e.key === " " || e.key === "Enter") && !e.repeat) { e.preventDefault(); void voiceRun("voiceTalk", { pressed: true }); } },
    onKeyUp: (e: ReactKeyboardEvent) => { if (e.key === " " || e.key === "Enter") { e.preventDefault(); void run("voiceTalk", { pressed: false }); } },
  };
  const pendingRows = state.proposals.filter(p => p.inScope && !p.isFinished);
  const rows = state.waitingApproval || state.canApprove || state.taskImport || pendingRows.some(p => p.state === "failed") ? pendingRows : [];
  const review = reviewRequested && rows.length > 0;
  const busy = state.running || state.saving || state.isRecognizing || state.isCapturing;
  const taskReview = state.taskReview;
  const working = busy && !state.question && !state.waitingApproval && !taskReview;
  const outcome = !busy && state.taskOutcome && ["partial", "failed", "denied", "unavailable"].includes(state.taskOutcome.status) && state.taskOutcome.id !== dismissedOutcome ? state.taskOutcome : undefined;
  const captured = Boolean(state.imageURL) && !state.messages.length && !state.proposals.length && !state.summary && !state.taskOutcome;
  const source = sourceRequested && (captured || rows.length > 0);
  const destination = state.calendars.find(c => c.id === state.selectedCalendarID);
  const detail = Boolean(state.personalMemory?.pending.length || voice?.error || voice?.needsAcknowledgement || state.question || taskReview || outcome || review || source || error || state.agentError || state.screenPermissionNeeded || state.notice);
  // Only clean, selected creates get a one-click shortcut. Other operations need visible review.
  const quickApprove = !state.taskImport && rows.length > 0 && rows.every(p => p.operation === "create" && p.isSelected && p.isApprovable && p.state !== "failed");
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
  }, [detail, review, state.question?.id, taskReview?.id, taskReview?.phase, outcome?.id, error, state.agentError]);
  useEffect(() => { setText(""); setReview(true); setSource(false); setError(""); }, [state.captureID]);
  useEffect(() => {
    const reset = () => {
      // Keep an unfinished editor mounted when pointer-leave hides the panel.
      // Returning to the notch restores its unsaved fields and focus trap.
      if (document.querySelector('[role="dialog"]')) return;
      setReview(true); setSource(false);
    };
    window.addEventListener("calshot:notch-collapsed", reset);
    return () => window.removeEventListener("calshot:notch-collapsed", reset);
  }, [rows.length]);
  useEffect(() => { setReview(true); }, [state.approvalToken]);
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      if (e.metaKey && e.key === ".") { e.preventDefault(); void run("stop"); }
      const interactive = e.target instanceof Element && e.target.closest('input,textarea,select,button,[contenteditable]:not([contenteditable="false"])');
      if (e.key === "Enter" && voice?.active && !compact && !e.repeat && !interactive && !document.querySelector('[role="dialog"]') && review && !state.question && !taskReview && !outcome && quickApprove && state.canApprove && state.waitingApproval && performance.now() - lastReturn.current >= 500) {
        lastReturn.current = performance.now(); e.preventDefault(); void run("approve", { token: state.approvalToken }); return;
      }
      if (e.key === "Escape" && voice?.active) { e.preventDefault(); void voiceRun("stopVoice"); return; }
      if (e.key === "Escape" && !document.querySelector('[role="dialog"]')) {
        e.preventDefault();
        if (review || source) { setReview(false); setSource(false); }
        else void run("collapseNotch");
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [compact, review, source, voice?.active, voice?.token, state.canApprove, state.approvalToken, state.waitingApproval, taskReview, quickApprove, outcome, state.question]);
  const submit = async () => {
    const message = text.trim();
    if ((!message && !captured) || busy || sending) return;
    setSending(true); setError("");
    try { await command(message ? { action: "send", text: message } : { action: "importCapturedScreenshot" }); setText(""); }
    catch (e) { setError((e as Error).message); }
    finally { setSending(false); }
  };
  if (state.auth?.required && (!state.auth.signedIn || !state.auth.onboarded)) return <div className="notch-shell"><div className="notch-bar"><span className="notch-label">{state.auth.busy ? "Checking your account…" : "Welcome to Calshot"}</span><button className="button primary" onClick={() => void run("openWorkspace")}>Open Calshot</button></div></div>;
  return <div className={"notch-shell" + (compact ? " is-compact" : "")}>
    <div className="notch-bar">
      {voice?.active && (compact || (!state.waitingApproval && !taskReview)) ? <>
        <VoicePill voice={voice} talkProps={talkProps}>
          {voice.talking && <span className="sr-only" role="meter" aria-label="Microphone level" aria-valuemin={0} aria-valuemax={1} aria-valuenow={voice.inputLevel} />}
          {voice.permissions.screen && <Eye size={14} className="voice-eye" role="img" aria-label="Calshot can see your screen" />}
          {voice.permissions.screen && !compact && <button className="voice-pill-action" aria-label={voice.drawing ? "Finish drawing" : "Draw focus"} aria-pressed={voice.drawing} onClick={() => void voiceRun("setVoiceDrawing", { drawing: !voice.drawing })}><ScanLine size={15} /></button>}
          <button className="voice-pill-action" aria-label={compact ? "Show task controls" : "Hide task controls"} aria-expanded={!compact} onClick={() => void run(compact ? "expandNotch" : "collapseNotch")}><ChevronDown size={15} /></button>
          <button className="voice-pill-action" aria-label="Stop" onClick={() => void voiceRun("stopVoice")}><X size={15} /></button>
        </VoicePill>
      </> : working ? <>
        <Spinner /><span className="notch-label" role="status">{state.agentStatus || (state.isRecognizing ? "Reading screenshot" : state.saving ? "Saving changes" : "Working…")}</span>
        <button className="button secondary" onClick={() => void run("stop")}><Square size={11} /> Stop</button>
      </> : taskReview ? <>
        <span className="notch-label" role="status">{taskReview.phase === "applying" ? "Saving the task change…" : "Review task change"}</span>
        <button className="text-button" onClick={() => void run("stop")}>Stop task</button>
      </> : rows.length && !state.question ? <>
        <span className="notch-label">{state.taskImport ? state.taskImport.items.length+" tasks to review" : rows.length+" "+(rows.length===1?"event":"events")+(rows.every(p=>p.operation==="create")&&destination?" → "+destination.title:" to review")}</span>
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
      {!voice?.active && <button className="icon-button" aria-label="Hold to talk" title={`Hold to talk (${voice?.shortcut || "⌃⇧V"})`} disabled={busy} {...talkProps}><Mic size={15} /></button>}
      <button className="icon-button notch-popout" aria-label="Open full app" title="Open full app" onClick={() => void run("openWorkspace")}><ExternalLink size={15} /></button>
    </div>
    {detail && <div className="notch-details" aria-hidden={compact} inert={compact ? true : undefined}>
      <div className="notch-detail-heading"><span>{state.question ? "Your answer stays in this task" : taskReview ? "Review task change" : outcome ? "Task result" : review ? "Review changes" : source ? "Captured screenshot" : "Needs attention"}</span><button className="icon-button" aria-label="Hide details" onClick={() => { if (outcome) setDismissedOutcome(outcome.id); else if (state.question || taskReview) void run("collapseNotch"); else { setReview(false); setSource(false); } }}><X size={14} /></button></div>
      <InlineError message={error || state.notice} />
      <InlineError message={voice?.error}>{voice?.needsKey ? <button onClick={() => void voiceRun("voiceAISettings")}>Open Settings → AI service</button> : <>{voice?.permissions && !voice.permissions.microphone && <button onClick={() => void voiceRun("voiceMicrophoneSettings")}>Microphone settings</button>}{voice?.permissions && !voice.permissions.screen && <button onClick={() => void run("screenSettings")}>Screen Recording settings</button>}</>}</InlineError>
      {voice?.needsAcknowledgement && <div><p>Microphone audio and screen frames are sent to OpenAI. Voice uses paid OpenAI Realtime API billing, including transcription, even when text uses your ChatGPT plan. Your text billing choice stays the same.</p><button className="button primary" onClick={() => void voiceRun("acknowledgeVoiceBilling")}>I understand</button></div>}
      {state.personalMemory?.pending.map(item => <div key={item.id}><p>Remember: {item.text}</p><button onClick={() => void run("approveMemory", { token: state.personalMemory!.token, memoryID: item.id, expectedVersion: item.version })}>Remember this</button><button onClick={() => void run("rejectMemory", { token: state.personalMemory!.token, memoryID: item.id, expectedVersion: item.version, dontSuggestAgain: false })}>Dismiss suggestion</button></div>)}
      <InlineError message={state.agentError}>{state.canRetry && <button className="text-button" onClick={() => void run("retryAgent")}>Try again</button>}</InlineError>
      {state.screenPermissionNeeded && <InlineError message={state.status || "Allow Screen Recording to capture your screen."}><button className="text-button" onClick={() => void run("screenSettings")}>Open Screen Recording settings</button></InlineError>}
      {state.question ? <Question key={state.question.id} question={state.question} /> : taskReview ? <TaskChangeReview key={taskReview.id} review={taskReview} compact /> : outcome ? <TaskOutcomeCard key={outcome.id} outcome={outcome} /> : review ? <Review state={{ ...state, proposals: rows }} /> : source ? <img className="notch-source" src={state.imageURL} alt="Source screenshot" /> : null}
      {!!rows.length && !state.question && <form className="notch-followup" onSubmit={e => { e.preventDefault(); void submit(); }}><input aria-label="Follow-up message" placeholder={busy ? "Approve or skip these changes to continue" : "Ask a follow-up…"} value={text} maxLength={8000} disabled={busy || sending} onChange={e => setText(e.target.value)} /><button className="button primary" disabled={busy || sending || !text.trim()} aria-label="Send follow-up"><ArrowUp size={14} /></button></form>}
      {!state.question && !busy && state.imageURL && (captured || rows.length > 0) && <div className="notch-footer"><button className="text-button" onClick={() => { setSource(!source); setReview(false); }}>View screenshot</button></div>}
    </div>}

  </div>;
}
