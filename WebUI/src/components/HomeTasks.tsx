import { Fragment, useState } from "react";
import { CalendarDays } from "lucide-react";
import type { AppState, Command } from "../types";
import { InlineError, Spinner } from "./ui";
import {
  localDay,
  nextTasks,
  taskCounts,
  taskDueLabel,
} from "../taskPresentation";

/**
 * Read-only Tasks summary for the Assistant start screen. It only navigates to
 * the Tasks page; every task change stays there, with the current native token.
 */
export function HomeTasks({
  state,
  onCommand,
}: {
  state: AppState;
  onCommand: (command: Command) => Promise<void>;
}) {
  const tasks = state.tasks;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  if (!tasks) return null;
  const today = localDay();
  const counts = taskCounts(tasks.items, today);
  const shown = nextTasks(tasks.items, today);
  const open = async () => {
    setError("");
    setBusy(true);
    try {
      await onCommand({ action: "navigate", page: "tasks" });
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const summary = [
    counts.open === 0 ? "Nothing open" : `${counts.open} open`,
    counts.overdue > 0 ? `${counts.overdue} overdue` : "",
    counts.dueToday > 0 ? `${counts.dueToday} due today` : "",
  ].filter(Boolean);
  return (
    <section className="home-tasks" aria-label="Tasks">
      <header className="home-tasks-head">
        <h2>Tasks</h2>
        {tasks.loaded && (
          <small className="home-tasks-summary">
            {summary.map((part, i) => (
              <Fragment key={part}>
                {i > 0 && " · "}
                <span className={part.endsWith("overdue") ? "task-overdue" : ""}>
                  {part}
                </span>
              </Fragment>
            ))}
          </small>
        )}
        <button className="text-button" onClick={() => void open()} disabled={busy}>
          {tasks.loaded && shown.length === 0 ? "Open Tasks" : "View all"}
        </button>
      </header>
      {!tasks.loaded ? (
        <p className="home-tasks-note" role="status">
          {tasks.error ? (
            "Tasks couldn’t be read yet. Your saved tasks are kept."
          ) : (
            <>
              <Spinner /> Loading your tasks…
            </>
          )}
        </p>
      ) : shown.length > 0 ? (
        <ul className="home-task-list">
          {shown.map((task) => {
            const due = taskDueLabel(task, today);
            return (
              <li key={task.id}>
                <button
                  className="home-task"
                  onClick={() => void open()}
                  disabled={busy}
                >
                  <span className="home-task-title">{task.title}</span>
                  <span
                    className={"home-task-due" + (due.overdue ? " task-overdue" : "")}
                  >
                    {task.dueDate && <CalendarDays size={12} />}
                    {due.text}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      ) : (
        <p className="home-tasks-note">No open tasks.</p>
      )}
      {tasks.error && tasks.loaded && (
        <p className="home-tasks-note task-overdue" role="alert">
          {tasks.error}
        </p>
      )}
      <InlineError message={error} />
    </section>
  );
}
