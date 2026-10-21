import type { AppState } from "../types";
import { InlineError, Spinner, formatDate } from "../components/ui";
import { useState } from "react";

export function SoftwareUpdates({ state, onAction }: {
  state: AppState;
  onAction: (action: string, extra?: Record<string, unknown>) => Promise<void>;
}) {
  const update = state.softwareUpdate;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  if (!update || !state.native) return null;
  const run = async (action: string, extra?: Record<string, unknown>) => {
    setBusy(true); setError("");
    try { await onAction(action, extra); }
    catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  };
  const disabled = busy || update.checking || !update.available || update.development;
  return <section aria-labelledby="software-updates-heading">
    <h2 className="section-label" id="software-updates-heading">Software updates</h2>
    <div className="card settings-card">
      <div className="settings-row">
        <div><h3>Calshot {update.version}</h3><p>Build {update.build} · macOS</p>
          <p role="status">{update.status}</p>
          {update.lastChecked && <p>Last checked {formatDate(update.lastChecked)}</p>}
        </div>
        <button className="button secondary" disabled={busy || !update.canCheck} onClick={() => void run("checkForUpdates")}>
          {busy && <Spinner />} Check for updates
        </button>
      </div>
      <div className="settings-row"><div><h3>Check automatically</h3><p>Look for new versions every six hours while Calshot runs.</p></div>
        <input type="checkbox" aria-label="Check for updates automatically" checked={update.automaticChecks} disabled={disabled}
          onChange={e => void run("updatePreferences", { checks: e.target.checked, downloads: update.automaticDownloads })} />
      </div>
      <div className="settings-row"><div><h3>Download updates automatically</h3><p>Download verified updates in the background and install when you quit. A restart waits until your current task is finished or cancelled.</p></div>
        <input type="checkbox" aria-label="Download updates automatically" checked={update.automaticDownloads} disabled={disabled || !update.automaticChecks}
          onChange={e => void run("updatePreferences", { checks: update.automaticChecks, downloads: e.target.checked })} />
      </div>
      {update.development && <p>Development build: automatic updates are off. You can still check the release feed manually.</p>}
      {!update.available && <p>Updates are unavailable in this preview.</p>}
      <InlineError message={error || update.error || ""} />
    </div>
  </section>;
}
