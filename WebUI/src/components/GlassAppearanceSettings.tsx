import { useEffect, useState, type CSSProperties } from "react";
import { Layers, RotateCcw } from "lucide-react";
import { command } from "../bridge";
import type { AppState, GlassAppearance } from "../types";
import { defaultGlass } from "../appearance";
import { InlineError, Spinner } from "./ui";

export function GlassAppearanceSettings({ state }: { state: AppState }) {
  const saved = state.settings.glass ?? defaultGlass;
  const [draft, setDraft] = useState<GlassAppearance>(saved);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState(false);
  useEffect(() => { setDraft(saved); }, [saved.enabled, saved.opacity, saved.blur, saved.contrast]);
  const change = (patch: Partial<GlassAppearance>) => { setDraft(d => ({ ...d, ...patch })); setError(""); setSuccess(false); };
  const dirty = draft.enabled !== saved.enabled || draft.opacity !== saved.opacity || draft.blur !== saved.blur || draft.contrast !== saved.contrast;
  const restricted = state.displayAccessibility?.reducedTransparency || state.displayAccessibility?.increasedContrast;
  const apply = async () => {
    if (busy) return;
    setBusy(true); setError(""); setSuccess(false);
    try { await command({ action: "glassAppearance", ...draft }); setSuccess(true); }
    catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  };
  return <section aria-labelledby="glass-heading" className="glass-settings">
    <h2 id="glass-heading" className="section-label">Liquid Glass</h2>
    <div className="card settings-card">
      <div className="settings-row">
        <div><h3 id="glass-enabled-label">Liquid Glass appearance</h3><p>A translucent window, luminous controls and softer layers.</p></div>
        <button type="button" role="switch" aria-labelledby="glass-enabled-label" aria-checked={draft.enabled} className={"switch" + (draft.enabled ? " is-on" : "")} disabled={busy} onClick={() => change({ enabled: !draft.enabled })}><i /></button>
      </div>
      <div className="glass-adjustments">
        {([
          ["opacity", "Window opacity", 35, 100, 1, Math.round(draft.opacity * 100), "%"],
          ["blur", "Surface blur", 0, 40, 1, draft.blur, ""],
          ["contrast", "Surface contrast", 0, 100, 1, Math.round(draft.contrast * 100), "%"],
        ] as const).map(([key, label, min, max, step, value, unit]) => <label key={key} className="glass-slider">
          <span>{label}<output>{value}{unit}</output></span>
          <input type="range" aria-label={label} min={min} max={max} step={step} value={value} disabled={busy || !draft.enabled}
            onChange={e => change({ [key]: Number(e.target.value) / (key === "blur" ? 1 : 100) })} />
        </label>)}
      </div>
      <div className={"glass-sample" + (draft.enabled ? " is-enabled" : "")} aria-label="Glass appearance preview" style={{ "--sample-opacity": draft.opacity, "--sample-blur": `${draft.blur}px`, "--sample-contrast": draft.contrast } as CSSProperties}>
        <div className="glass-sample-backdrop" aria-hidden />
        <div className="glass-sample-surface"><Layers size={19} /><div><strong>Your day, in focus</strong><p>Preview of the glass surface</p></div><span className="glass-sample-chip">Calshot</span></div>
      </div>
      <p className="fine-print">Lower opacity reveals more of what’s behind the window. Higher contrast gives surfaces a stronger edge. Saved on this Mac.</p>
      {restricted && <p className="glass-accessibility-note" role="status">Your Mac’s accessibility settings currently use solid, higher-contrast surfaces. Your glass choices are kept.</p>}
      <InlineError message={error} />
      <div className="glass-settings-actions">
        <button className="text-button" disabled={busy} onClick={() => change(defaultGlass)}><RotateCcw size={13} /> Reset to defaults</button>
        <span role="status">{busy ? "Saving appearance…" : success ? "Appearance saved" : dirty ? "Preview · changes not applied" : ""}</span>
        <button className="button primary" disabled={busy || !dirty} onClick={() => void apply()}>{busy && <Spinner />}Apply appearance</button>
      </div>
    </div>
  </section>;
}
