import { useState } from "react";
import { ArrowRight, CalendarPlus, PencilLine, RotateCcw, Trash2, Undo2 } from "lucide-react";
import type { RecentChange, RecentChangesState } from "../types";
import { command } from "../bridge";
import { Spinner } from "./ui";

const verbs: Record<RecentChange["operation"], string> = { create: "Added", update: "Changed", delete: "Removed", move: "Moved" };
const icons = { create: CalendarPlus, update: PencilLine, delete: Trash2, move: ArrowRight } as const;

function when(change: RecentChange) {
  if (!change.start) return "";
  const start = new Date(change.start);
  if (!Number.isFinite(+start)) return "";
  const day = start.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
  return change.allDay ? `${day} · All day` : `${day} · ${start.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}`;
}
export function describeChange(change: RecentChange) {
  if (change.isUndo) return `Undid: ${change.title}`;
  if (change.operation === "move") return `${change.title} → ${change.calendar}`;
  if (change.operation === "update" && change.previousTitle && change.previousTitle !== change.title) return `${change.previousTitle} → ${change.title}`;
  return change.title;
}

/** Saved calendar changes, newest first, each with its own Undo. Results come only from native receipts. */
export function RecentChanges({ changes, limit = 5, since, heading = "What Calshot did", hideHeading = false }: { changes?: RecentChangesState; limit?: number; since?: number; heading?: string; hideHeading?: boolean }) {
  const [error, setError] = useState<{ id: string; message: string } | null>(null);
  const [pending, setPending] = useState("");
  const rows = (changes?.items || []).filter(c => since === undefined || (c.savedAt && Date.parse(c.savedAt) >= since)).slice(0, limit);
  if (!changes || !rows.length) return null;
  const undo = async (change: RecentChange) => {
    setPending(change.id); setError(null);
    try { await command({ action: "undoChange", changeID: change.id, token: changes.token }); }
    catch (e) { setError({ id: change.id, message: (e as Error).message }); }
    finally { setPending(""); }
  };
  return <section className="recent-changes" aria-label={heading}>
    {!hideHeading && <h3 className="recent-changes-heading">{heading}</h3>}
    <ul>
      {rows.map(change => {
        const Icon = change.isUndo ? RotateCcw : icons[change.operation];
        const busy = change.undoing || pending === change.id;
        const message = (error?.id === change.id ? error.message : "") || change.error;
        return <li key={change.id} className="recent-change" data-undone={change.undone || undefined}>
          <Icon size={14} aria-hidden />
          <span className="recent-change-text">
            <strong title={describeChange(change)}>{describeChange(change)}</strong>
            <small>{[change.isUndo ? "" : verbs[change.operation], when(change), change.operation === "move" ? `from ${change.fromCalendar}` : change.calendar].filter(Boolean).join(" · ")}</small>
            {message && <span className="recent-change-error" role="alert">{message}</span>}
          </span>
          {change.undone ? <span className="recent-change-state">Undone</span>
            : change.canUndo ? <button className="button secondary recent-change-undo" disabled={busy || !!pending} aria-label={`Undo ${verbs[change.operation].toLowerCase()} ${change.title}`} onClick={() => void undo(change)}>
              {busy ? <Spinner /> : <Undo2 size={13} aria-hidden />}<span className="recent-change-undo-label">Undo</span>
            </button> : null}
        </li>;
      })}
    </ul>
  </section>;
}
