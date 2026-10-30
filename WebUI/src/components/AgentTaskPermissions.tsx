import { useEffect, useMemo, useState } from "react";
import type { AppState } from "../types";
import { command } from "../bridge";
import { InlineError, Select, Spinner, formatDate } from "./ui";

/**
 * Device-local grants for task actions the user asks Calshot to perform. Nothing is enabled automatically,
 * background actions do not exist, and calendar changes are never covered by these choices.
 */
export function AgentTaskPermissions({ state }: { state: AppState }) {
  const permissions = state.agentPermissions;
  const saved = useMemo(
    () => Object.fromEntries((permissions?.families || []).map((f) => [f.id, f.enabled])),
    [permissions?.revision, permissions?.loaded],
  );
  const [draft, setDraft] = useState<Record<string, boolean>>(saved),
    [days, setDays] = useState("30"),
    [daysChosen, setDaysChosen] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  useEffect(() => { setDraft(saved); setDaysChosen(false); }, [saved]);
  useEffect(() => { void command({ action: "loadAgentPermissions" }).catch(() => {}); }, []);
  if (!permissions) return null;
  const anyOn = Object.values(draft).some(Boolean);
  // Choosing a period for actions that are already on is an explicit renewal.
  const dirty = Object.keys(saved).some((id) => Boolean(draft[id]) !== Boolean(saved[id])) || (daysChosen && anyOn);
  const locked = busy || permissions.busy || state.running || !permissions.loaded;
  const save = async () => {
    setBusy(true);
    setError("");
    try {
      await command({ action: "saveAgentPermissions", revision: permissions.revision, families: draft, days: Number(days), renew: daysChosen });
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <section aria-labelledby="task-actions-heading">
      <h2 className="section-label" id="task-actions-heading">Task actions</h2>
      <div className="card settings-card agent-permissions">
        <p className="fine-print">
          By default Calshot asks you to review every task change. Choose the routine ones it may save right away
          when you ask. Calendar changes have their own choices below. These choices stay on this Mac and are not synced.
        </p>
        <InlineError message={permissions.error || ""} />
        {!permissions.loaded && !permissions.error && <p className="fine-print" role="status"><Spinner /> Loading task permissions…</p>}
        {permissions.families.map((family) => (
          <div className="settings-row" key={family.id}>
            <div>
              <h3 id={"perm-" + family.id}>{family.label}</h3>
              <p>
                {family.detail}
                {family.expired && " Earlier permission expired. Turn it on and save to renew it."}
              </p>
            </div>
            <input
              type="checkbox"
              aria-labelledby={"perm-" + family.id}
              checked={Boolean(draft[family.id])}
              disabled={locked || Boolean(permissions.error)}
              onChange={(e) => setDraft({ ...draft, [family.id]: e.target.checked })}
            />
          </div>
        ))}
        <div className="settings-row">
          <div>
            <h3>Allow for</h3>
            <p>
              {permissions.expiresAt
                ? "Current permission ends " + formatDate(permissions.expiresAt, undefined, { month: "short", day: "numeric", year: "numeric" }) + ". Choose a period and save to renew."
                : "Permissions end automatically. Save to start the period."}
            </p>
          </div>
          <Select label="Allow for" value={days} disabled={locked || !anyOn} onChange={(value) => { setDays(value); setDaysChosen(true); }}>
            <option value="7">7 days</option>
            <option value="30">30 days</option>
            <option value="90">90 days</option>
          </Select>
        </div>
        <p className="fine-print">
          Calshot makes task changes only when you ask. It never changes tasks in the background. A single request is
          limited to {permissions.limits.perRun} task changes, and {permissions.limits.perWindow} per hour in total; anything
          larger waits for your review. Turn a switch off and save to go back to reviewing that kind of change.
        </p>
        <div className="settings-row permissions-save">
          <div aria-live="polite">
            {error ? <InlineError message={error} /> : permissions.notice ? <p>{permissions.notice}</p> : dirty ? <p>Unsaved changes.</p> : null}
          </div>
          <button className="button primary" disabled={locked || !dirty || Boolean(permissions.error)} onClick={() => void save()}>
            {busy && <Spinner />}Save task permissions
          </button>
        </div>
      </div>
    </section>
  );
}
