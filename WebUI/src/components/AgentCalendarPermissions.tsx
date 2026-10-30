import { useEffect, useMemo, useState } from "react";
import type { AppState } from "../types";
import { command } from "../bridge";
import { InlineError, Select, Spinner, formatDate } from "./ui";

/**
 * Device-local calendar grants. Off by default; only clear, single, guest-free, non-repeating events the user asked
 * for save without review, and only in the checked calendars. Guests, repeating series and screenshot imports always ask.
 */
export function AgentCalendarPermissions({ state }: { state: AppState }) {
  const permissions = state.agentPermissions, calendar = permissions?.calendar;
  const writable = (state.calendars || []).filter((c) => !c.isReadOnly && !c.unavailable);
  const savedFamilies = useMemo(
    () => Object.fromEntries((calendar?.families || []).filter((f) => !f.alwaysAsks).map((f) => [f.id, f.enabled])),
    [permissions?.revision, permissions?.loaded],
  );
  const savedIDs = useMemo(() => {
    const ids = calendar?.calendarIDs || [];
    return ids.length ? ids : state.selectedCalendarID ? [state.selectedCalendarID] : [];
  }, [permissions?.revision, permissions?.loaded, state.selectedCalendarID]);
  const [draft, setDraft] = useState<Record<string, boolean>>(savedFamilies),
    [ids, setIDs] = useState<string[]>(savedIDs),
    [days, setDays] = useState("30"),
    [daysChosen, setDaysChosen] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  useEffect(() => { setDraft(savedFamilies); setIDs(savedIDs); setDaysChosen(false); }, [savedFamilies, savedIDs]);
  if (!permissions || !calendar) return null;
  const anyOn = Object.values(draft).some(Boolean);
  const sameIDs = ids.length === savedIDs.length && ids.every((id) => savedIDs.includes(id));
  const dirty = Object.keys(savedFamilies).some((id) => Boolean(draft[id]) !== Boolean(savedFamilies[id])) || (anyOn && !sameIDs) || (daysChosen && anyOn);
  const locked = busy || permissions.busy || state.running || !permissions.loaded;
  const save = async () => {
    setBusy(true); setError("");
    try { await command({ action: "saveCalendarPermissions", revision: permissions.revision, families: draft, calendarIDs: ids, days: Number(days), renew: daysChosen }); }
    catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  };
  return (
    <section aria-labelledby="calendar-actions-heading">
      <h2 className="section-label" id="calendar-actions-heading">Calendar actions</h2>
      <div className="card settings-card agent-permissions">
        <p className="fine-print">
          By default Calshot asks you to approve every calendar change. Turn these on to let it save clear requests right away
          when you type or speak them. Anything unclear, repeating, with guests or from a screenshot still asks first.
        </p>
        <InlineError message={permissions.error || ""} />
        {calendar.families.map((family) => (
          <div className="settings-row" key={family.id}>
            <div>
              <h3 id={"cal-perm-" + family.id}>{family.label}</h3>
              <p>{family.detail}{family.expired && " Earlier permission expired. Turn it on and save to renew it."}</p>
            </div>
            {family.alwaysAsks
              ? <span className="fine-print">Always asks</span>
              : <input type="checkbox" aria-labelledby={"cal-perm-" + family.id} checked={Boolean(draft[family.id])}
                  disabled={locked || Boolean(permissions.error)} onChange={(e) => setDraft({ ...draft, [family.id]: e.target.checked })} />}
          </div>
        ))}
        <div className="settings-row">
          <div>
            <h3 id="cal-perm-scope">Calendars</h3>
            <p>{writable.length ? "Calshot saves without asking only in the calendars you check." : "Connect a writable calendar to use these choices."}</p>
            {writable.map((c) => (
              <label className="inline-check" key={c.id}>
                <input type="checkbox" checked={ids.includes(c.id)} disabled={locked || !anyOn}
                  onChange={(e) => setIDs(e.target.checked ? [...ids, c.id] : ids.filter((id) => id !== c.id))} />
                {c.title} <span className="fine-print">{c.sourceName}</span>
              </label>
            ))}
          </div>
        </div>
        <div className="settings-row">
          <div>
            <h3>Allow for</h3>
            <p>{calendar.expiresAt
              ? "Current permission ends " + formatDate(calendar.expiresAt, undefined, { month: "short", day: "numeric", year: "numeric" }) + ". Choose a period and save to renew."
              : "Permissions end automatically. Save to start the period."}</p>
          </div>
          <Select label="Allow calendar actions for" value={days} disabled={locked || !anyOn} onChange={(value) => { setDays(value); setDaysChosen(true); }}>
            <option value="7">7 days</option>
            <option value="30">30 days</option>
            <option value="90">90 days</option>
          </Select>
        </div>
        <div className="settings-row permissions-save">
          <div aria-live="polite">
            {error ? <InlineError message={error} /> : calendar.notice ? <p>{calendar.notice}</p> : dirty ? <p>Unsaved changes.</p> : null}
          </div>
          <button className="button primary" disabled={locked || !dirty || Boolean(permissions.error) || (anyOn && !ids.length)} onClick={() => void save()}>
            {busy && <Spinner />}Save calendar permissions
          </button>
        </div>
      </div>
    </section>
  );
}
