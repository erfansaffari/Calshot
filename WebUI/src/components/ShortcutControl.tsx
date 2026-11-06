import { useEffect, useRef, useState } from "react";
import { command } from "../bridge";
import type { AppState } from "../types";
import { InlineError } from "./ui";

/** Native code reads the key press, registers it and reports the result. This only starts or cancels listening. */
export function ShortcutControl({ state, target, title, description }: {
  state: AppState;
  target: "capture" | "voice";
  title: string;
  description: string;
}) {
  const [requestError, setRequestError] = useState("");
  const [busy, setBusy] = useState(false);
  const shortcuts = state.shortcuts, entry = shortcuts?.[target];
  const token = state.voice?.token;
  const recording = shortcuts?.recording === target;
  const label = entry?.label || (target === "capture" ? state.shortcut : state.voiceShortcut) || "";
  const latest = useRef({ token, recording });
  latest.current = { token, recording };
  // Listening turns both global shortcuts off, so leaving this control must end it.
  useEffect(() => () => {
    if (latest.current.recording) void command({ action: "shortcutRecording", token: latest.current.token, target, enabled: false }).catch(() => {});
  }, [target]);
  const run = async (action: string, extra: Record<string, unknown> = {}) => {
    setRequestError(""); setBusy(true);
    try { await command({ action, token, target, ...extra }); }
    catch (e) { setRequestError((e as Error).message); }
    finally { setBusy(false); }
  };
  const unavailable = !shortcuts || !token || Boolean(state.voice?.active);
  const errorID = `shortcut-${target}-error`;
  const error = requestError || entry?.error || "";
  return <div className="settings-row shortcut-row">
    <div>
      <h3>{title}</h3>
      <p>{state.voice?.active ? "Stop voice to change this." : recording ? (target === "voice" ? "Press the new shortcut with ⌃ or ⌘, or press and release modifiers alone, like ⌃⌥. Esc cancels." : "Press the new shortcut, with ⌃ or ⌘. Esc cancels.") : description}</p>
    </div>
    <div className="shortcut-actions">
      {entry && !entry.isDefault && !recording && <button className="text-button" disabled={unavailable || busy} onClick={() => void run("resetShortcut")}>Reset</button>}
      {recording && <button className="text-button" disabled={busy} onClick={() => void run("shortcutRecording", { enabled: false })}>Cancel</button>}
      <button className={"button secondary shortcut-key" + (recording ? " is-recording" : "")} aria-pressed={recording} aria-describedby={error ? errorID : undefined} disabled={unavailable || busy}
        onClick={() => void run("shortcutRecording", { enabled: !recording })}>{recording ? "Press shortcut…" : label}</button>
    </div>
    {error && <div id={errorID} className="shortcut-error"><InlineError message={error} /></div>}
  </div>;
}
