import { useState } from "react";
import type { AppState } from "../types";
import { command } from "../bridge";
import { InlineError, Spinner } from "./ui";
import { AgentTaskPermissions } from "./AgentTaskPermissions";
import { AgentCalendarPermissions } from "./AgentCalendarPermissions";

/** One switch for routine autonomy; the detailed task and calendar choices live under Customize. */
export function AgentAutonomy({ state }: { state: AppState }) {
  const permissions = state.agentPermissions;
  const [busy, setBusy] = useState(false), [error, setError] = useState(""), [open, setOpen] = useState(false);
  if (!permissions) return null;
  const families = [...permissions.families, ...(permissions.calendar?.families.filter((f) => !f.alwaysAsks) || [])];
  const on = families.length > 0 && families.every((f) => f.enabled);
  const partial = !on && families.some((f) => f.enabled);
  const locked = busy || permissions.busy || state.running || !permissions.loaded || Boolean(permissions.error);
  const toggle = async () => {
    setBusy(true); setError("");
    try { await command({ action: "saveAutonomy", revision: permissions.revision, enabled: !on }); }
    catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  };
  return (
    <section aria-labelledby="autonomy-heading">
      <h2 className="section-label" id="autonomy-heading">Autonomy</h2>
      <div className="card settings-card agent-permissions">
        <div className="settings-row">
          <div>
            <h3 id="autonomy-label">Let Calshot act without asking {busy && <Spinner />}</h3>
            <p>
              Requests you type or say are saved right away: adding, editing, deleting and moving events, and every task change.
              Say “undo” to reverse a change. Events with guests, repeating events and anything from a screenshot still ask first.
              {partial && " Some actions are already on; switching this on turns on the rest."}
            </p>
          </div>
          <button type="button" role="switch" aria-checked={on} aria-labelledby="autonomy-label" className={"switch" + (on ? " is-on" : "")}
            disabled={locked} onClick={() => void toggle()}><i /></button>
        </div>
        <InlineError message={error || permissions.error || ""} />
        <button type="button" className="text-button" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? "Hide details" : "Customize"}</button>
      </div>
      {open && <><AgentTaskPermissions state={state} /><AgentCalendarPermissions state={state} /></>}
    </section>
  );
}
