import { useEffect, useRef, useState } from "react";
import { AlertTriangle, Check, ListChecks, X } from "lucide-react";
import type { TaskOutcome, TaskReview } from "../types";
import { command } from "../bridge";
import { Badge, InlineError, Spinner } from "./ui";

const confirmLabel: Record<TaskReview["kind"], string> = {
  link: "Add to Tasks",
  edit: "Save changes",
  complete: "Save changes",
  archive: "Save changes",
};
function reasonText(reason: string, compact: boolean) {
  if (/screenshot/i.test(reason)) return "A screenshot started this, so Calshot asks before changing your tasks.";
  if (/limit/i.test(reason)) return "This is more changes than your saved limit allows without checking.";
  return compact
    ? "Calshot asks first for this kind of task change."
    : "Calshot asks first for this kind of task change. You can allow routine ones in Settings.";
}

/** One short, task-only review inside the current conversation or notch. Never a calendar approval. */
export function TaskChangeReview({ review, compact = false }: { review: TaskReview; compact?: boolean }) {
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    root = useRef<HTMLElement>(null);
  const applying = review.phase === "applying" || busy;
  useEffect(() => { root.current?.focus({ preventScroll: true }); }, [review.id]);
  const act = async (action: "approveTaskChange" | "cancelTaskChange") => {
    if (applying) return;
    setBusy(true);
    setError("");
    try {
      await command({ action, reviewID: review.id, token: review.token, ...(action === "approveTaskChange" ? { digest: review.digest } : {}) });
    } catch (e) {
      setError((e as Error).message);
      setBusy(false);
    }
  };
  return (
    <section
      ref={root}
      tabIndex={-1}
      className="card task-review"
      aria-label="Task change review"
      onKeyDown={(e) => {
        if (e.metaKey && e.key === "Enter" && !applying) { e.preventDefault(); e.stopPropagation(); void act("approveTaskChange"); }
      }}
    >
      <Badge><ListChecks size={11} />Task review</Badge>
      <h2>{review.heading}</h2>
      {!applying && <p className="fine-print">{reasonText(review.reason, compact)}</p>}
      <ul className="task-review-rows" aria-label="Task changes" tabIndex={review.rows.length > 4 ? 0 : undefined}>
        {review.rows.map((row) => (
          <li key={row.id}>
            <strong>{row.title}</strong>
            {row.changes.map((change) => (
              <p key={change.label}>
                <span className="task-review-label">{change.label}</span>{" "}
                {change.before != null && <><span className="task-review-before">{change.before}</span> → </>}
                <span className="task-review-after">{change.after ?? "None"}</span>
              </p>
            ))}
            {row.note && <small>{row.note}</small>}
          </li>
        ))}
      </ul>
      <p className="fine-print">{review.calendarWrites === 0 ? "Your calendar isn’t changed." : ""}</p>
      <InlineError message={error || review.error || ""} />
      <footer>
        <button className="button secondary" disabled={applying} onClick={() => void act("cancelTaskChange")}>Cancel</button>
        <button className="button primary" disabled={applying} onClick={() => void act("approveTaskChange")}>
          {applying ? <><Spinner /> Saving…</> : confirmLabel[review.kind]}
        </button>
      </footer>
    </section>
  );
}

const statusLabel: Record<string, string> = {
  saved: "Saved", alreadyLinked: "Already in Tasks", alreadyLinkedArchived: "Already in Tasks (archived)",
  failed: "Not saved", cancelled: "Stopped", denied: "Not allowed", unavailable: "Unavailable", skipped: "Skipped",
};
/** Receipt-based result. Appears only after native task storage confirms (or fails to confirm) each row. */
export function TaskOutcomeCard({ outcome }: { outcome: TaskOutcome }) {
  const ok = outcome.status === "saved";
  const hidden = Math.max(0, outcome.rows.length - 12);
  return (
    <section className={"card task-outcome " + (ok ? "is-ok" : "is-problem")} role="status" aria-label="Task result">
      <header>
        {ok ? <Check size={14} /> : outcome.status === "declined" || outcome.status === "cancelled" ? <X size={14} /> : <AlertTriangle size={14} />}
        <strong>{outcome.headline}</strong>
        {outcome.viaSavedPermission && ok && <small>Allowed in Settings</small>}
      </header>
      {outcome.rows.length > 0 && (
        <ul>
          {outcome.rows.slice(0, 12).map((row) => (
            <li key={row.id} className={"row-" + row.status}>
              <span>{row.title}</span>
              <small>{statusLabel[row.status] || row.status}</small>
              {row.message && <p role={row.status === "failed" ? "alert" : undefined}>{row.message}</p>}
            </li>
          ))}
        </ul>
      )}
      {hidden > 0 && <small>and {hidden} more</small>}
    </section>
  );
}
