import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  ArrowDown,
  ArrowUp,
  Check,
  ListTodo,
  Plus,
  RefreshCw,
  GripVertical,
  CalendarDays,
  Bell,
} from "lucide-react";
import type { AppState, CalshotTask, Command } from "../types";
import { Empty, InlineError, Modal, Spinner } from "../components/ui";

type Filter = "all" | "today" | "upcoming" | "inbox" | "completed" | "archived";
export function taskNeedsPublication(task: CalshotTask) {
  const fingerprint = [
    task.title,
    task.dueDate || "",
    task.dueTime || "",
    task.timeZone,
    task.notes,
    task.calendarID || "",
  ].join("\x1f");
  return (
    !task.deleted &&
    Boolean(task.dueDate || task.receipt) &&
    task.publishedFingerprint !== fingerprint
  );
}
const localDay = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};
export function taskDue(task: CalshotTask) {
  if (!task.dueDate) return "No deadline";
  const d = new Date(task.dueDate + "T12:00:00");
  const day = d.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
  if (!task.dueTime) return day + " · Date only";
  const [h, m] = task.dueTime.split(":").map(Number);
  const t = new Date(2000, 0, 1, h, m).toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
  return day + " · Due " + t + " · " + task.timeZone;
}
export function TasksPage({
  state,
  onCommand,
  readOnly = false,
  deadlineReview,
}: {
  state: AppState;
  onCommand: (command: Command) => Promise<void>;
  readOnly?: boolean;
  deadlineReview?: ReactNode;
}) {
  const tasks = state.tasks;
  const [filter, setFilter] = useState<Filter>("all");
  const [sort, setSort] = useState("manual");
  const [editing, setEditing] = useState<CalshotTask | "new">();
  const [editToken, setEditToken] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [announcement, setAnnouncement] = useState("");
  const [reload, setReload] = useState(0);
  const dragged = useRef<string | undefined>(undefined);
  const rowRefs = useRef<Record<string, HTMLButtonElement | null>>({});
  const today = localDay();
  const ordered = useMemo(
    () =>
      (tasks?.items || [])
        .filter((t) =>
          filter === "archived"
            ? t.deleted
            : !t.deleted &&
              (filter === "completed" ? t.completed : !t.completed) &&
              (filter === "inbox"
                ? !t.dueDate
                : filter === "today"
                  ? Boolean(t.dueDate && t.dueDate <= today)
                  : filter === "upcoming"
                    ? Boolean(t.dueDate && t.dueDate > today)
                    : true),
        )
        .sort((a, b) =>
          sort === "due"
            ? (a.dueDate || "9999").localeCompare(b.dueDate || "9999") ||
              a.rank - b.rank
            : a.rank - b.rank || a.id.localeCompare(b.id),
        ),
    [tasks?.items, filter, sort, today],
  );
  const fullOrder = (tasks?.items || [])
    .filter((t) => !t.deleted && !t.completed)
    .sort((a, b) => a.rank - b.rank || a.id.localeCompare(b.id));
  const conversationBusy =
    state.running || state.isCapturing || state.isRecognizing;
  const pending =
    busy || Boolean(tasks?.busy) || state.saving || conversationBusy;
  const reviewRef = useRef<HTMLElement>(null);
  const reviewedTaskIDs = new Set(
    state.proposals
      .filter((p) => !p.isFinished && p.isSelected)
      .map((p) => p.draft.taskID),
  );
  const run = async (action: string, extra: Record<string, unknown> = {}) => {
    setError("");
    setBusy(true);
    try {
      await onCommand({ action, token: tasks?.token, ...extra });
    } catch (e) {
      setError((e as Error).message);
      throw e;
    } finally {
      setBusy(false);
    }
  };
  const open = (task: CalshotTask | "new") => {
    setEditToken(tasks?.token || "");
    setEditing(task);
    setError("");
  };
  const move = async (task: CalshotTask, offset: number) => {
    try {
      await run("reorderTask", { taskID: task.id, offset });
      setAnnouncement(
        `${task.title} moved ${offset < 0 ? "up" : "down"}. Deadline unchanged.`,
      );
      requestAnimationFrame(() => rowRefs.current[task.id]?.focus());
    } catch {}
  };
  const review =
    !readOnly &&
    (Boolean(state.taskImport) ||
      state.proposals.some((p) => p.inScope && p.draft.taskID));
  const reviewKey = review
    ? state.proposals
        .filter((p) => p.inScope && p.draft.taskID)
        .map((p) => p.id)
        .join(":") + (state.taskImport?.id || "")
    : "";
  useEffect(() => {
    if (reviewKey)
      reviewRef.current?.scrollIntoView?.({
        block: "start",
        behavior: window.matchMedia?.("(prefers-reduced-motion: reduce)")
          .matches
          ? "instant"
          : "smooth",
      });
  }, [reviewKey]);
  return (
    <div className="page-scroll">
      <div className="page-inner tasks-page">
        <header className="page-title">
          <div>
            <p className="eyebrow">YOUR WORK, IN ORDER</p>
            <h1>Tasks</h1>
            <p className="muted">
              Keep track of what to finish. Review dated tasks to add their
              deadlines to your calendar.
            </p>
          </div>
          <div className="tasks-header-actions">
            <button
              className="button secondary"
              disabled={pending}
              onClick={() => void run("syncTasks").catch(() => {})}
            >
              <RefreshCw size={14} />
              {tasks?.busy ? "Syncing…" : "Sync"}
            </button>
            {!readOnly && (
              <button
                className="button primary"
                disabled={pending || !tasks?.loaded}
                onClick={() => open("new")}
              >
                <Plus size={15} />
                New task
              </button>
            )}
          </div>
        </header>
        {error && <InlineError message={error} />}
        {tasks?.error && (
          <div className="tasks-notice" role="alert">
            <InlineError message={tasks.error} />
            {tasks.conflict && !readOnly && (
              <button
                className="button secondary"
                disabled={pending}
                onClick={() => void run("keepTaskCopies").catch(() => {})}
              >
                Keep both versions and sync
              </button>
            )}
          </div>
        )}
        {tasks?.reminderError && (
          <div className="tasks-notice" role="alert">
            <p>{tasks.reminderError}</p>
            {!readOnly && (
              <button
                className="button secondary"
                onClick={() =>
                  void run("taskNotificationSettings").catch(() => {})
                }
              >
                Notification settings
              </button>
            )}
          </div>
        )}
        {readOnly && (
          <p className="task-web-note">
            Manage tasks and approve calendar deadlines in the{" "}
            <a href="calshot://">Mac app</a>. This view uses your synced task
            list.
          </p>
        )}
        {review && (
          <section
            ref={reviewRef}
            className="tasks-review"
            aria-label="Task deadline calendar review"
          >
            <h2>Review calendar deadlines</h2>
            <p className="muted">
              These entries appear above the timetable and do not reserve work
              time. Exact due times remain in their titles and notes.
            </p>
            {deadlineReview}
          </section>
        )}
        {conversationBusy && (
          <p className="tasks-notice">
            Finish or stop the current conversation before changing tasks.{" "}
            <button
              className="button secondary"
              onClick={() =>
                void onCommand({ action: "navigate", page: "chat" }).catch(
                  () => {},
                )
              }
            >
              View conversation
            </button>
          </p>
        )}
        <div className="tasks-toolbar">
          <div className="tasks-filters" role="group" aria-label="Task views">
            {(
              [
                ["all", "All tasks"],
                ["today", "Today & overdue"],
                ["upcoming", "Upcoming"],
                ["inbox", "Inbox"],
                ["completed", "Completed"],
                ["archived", "Archived"],
              ] as [Filter, string][]
            ).map(([id, label]) => (
              <button
                key={id}
                aria-pressed={filter === id}
                onClick={() => setFilter(id)}
              >
                {label}
              </button>
            ))}
          </div>
          <label className="task-sort">
            Order
            <select
              aria-label="Task order"
              value={sort}
              onChange={(e) => setSort(e.target.value)}
            >
              <option value="manual">Manual</option>
              <option value="due">Due date</option>
            </select>
          </label>
        </div>
        {!tasks?.loaded ? (
          <div className="tasks-empty">
            <Spinner />
            <p>
              {tasks?.error
                ? "Your tasks are kept. Reload to try reading them again."
                : "Loading your tasks…"}
            </p>
            {!readOnly && (
              <button
                className="button secondary"
                onClick={() => void run("reloadTasks").catch(() => {})}
              >
                Reload tasks
              </button>
            )}
          </div>
        ) : ordered.length === 0 ? (
          <Empty
            icon={<ListTodo size={28} />}
            title={
              filter === "all"
                ? "A little space for what’s next."
                : "No tasks in this view."
            }
          >
            {filter === "all"
              ? "Add a task with just a title. Choose a deadline when you know it."
              : "Your other tasks are still available in All tasks."}
          </Empty>
        ) : (
          <div className="task-list" aria-label="Task list">
            {ordered.map((task) => {
              const index = fullOrder.findIndex((t) => t.id === task.id),
                canMove =
                  !readOnly &&
                  filter === "all" &&
                  sort === "manual" &&
                  !task.completed;
              const needs = taskNeedsPublication(task);
              return (
                <article
                  className={
                    "task-item" + (task.completed ? " task-completed" : "")
                  }
                  key={task.id}
                  draggable={canMove && !pending}
                  onDragStart={(e) => {
                    dragged.current = task.id;
                    e.dataTransfer.setData("text/plain", task.id);
                    e.dataTransfer.effectAllowed = "move";
                  }}
                  onDragOver={(e) => {
                    if (canMove) e.preventDefault();
                  }}
                  onDrop={(e) => {
                    e.preventDefault();
                    const source = fullOrder.findIndex(
                      (t) => t.id === dragged.current,
                    );
                    if (canMove && source >= 0 && source !== index) {
                      const t = fullOrder[source];
                      void run("reorderTask", {
                        taskID: t.id,
                        targetTaskID: task.id,
                      }).catch(() => {});
                    }
                    dragged.current = undefined;
                  }}
                >
                  <span className="task-grip" aria-hidden="true">
                    <GripVertical size={15} />
                  </span>
                  <input
                    type="checkbox"
                    aria-label={
                      (task.completed ? "Reopen " : "Complete ") + task.title
                    }
                    checked={task.completed}
                    disabled={
                      pending ||
                      readOnly ||
                      task.deleted ||
                      reviewedTaskIDs.has(task.id)
                    }
                    onChange={(e) =>
                      void run("completeTask", {
                        taskID: task.id,
                        completed: e.target.checked,
                      }).catch(() => {})
                    }
                  />
                  <div className="task-item-main">
                    <button
                      className="task-open"
                      ref={(el) => {
                        rowRefs.current[task.id] = el;
                      }}
                      onClick={() => open(task)}
                    >
                      {task.title}
                    </button>
                    <div className="task-meta">
                      <span
                        className={
                          !task.completed &&
                          task.dueDate &&
                          task.dueDate < today
                            ? "task-overdue"
                            : ""
                        }
                      >
                        <CalendarDays size={12} />
                        {taskDue(task)}
                      </span>
                      {task.calendarName && <span>{task.calendarName}</span>}
                      {task.reminderMinutes != null && (
                        <span>
                          <Bell size={12} />
                          {task.reminderMinutes === 0
                            ? "At deadline"
                            : task.reminderMinutes === 60
                              ? "1 hour before"
                              : "1 day before"}
                          {task.reminderDeviceID !== tasks.deviceID
                            ? " · source Mac"
                            : " · this Mac"}
                        </span>
                      )}
                    </div>
                    {task.calendarError && (
                      <p className="task-row-error" role="alert">
                        {task.calendarError}
                      </p>
                    )}
                    {needs && !task.calendarError && (
                      <p className="task-publish-status">
                        {task.receipt
                          ? "Deadline changes need calendar review."
                          : "Task saved · deadline needs calendar review."}
                      </p>
                    )}
                    {!needs && task.receipt && (
                      <p className="task-publish-status">
                        <Check size={11} />
                        Calendar deadline confirmed
                      </p>
                    )}
                  </div>
                  <div className="task-item-actions">
                    {needs && !readOnly && !task.completed && (
                      <button
                        className="button secondary"
                        disabled={pending || reviewedTaskIDs.has(task.id)}
                        onClick={() =>
                          void run("reviewTaskDeadline", {
                            taskID: task.id,
                          }).catch(() => {})
                        }
                      >
                        Review deadline
                      </button>
                    )}
                    {canMove && (
                      <>
                        <button
                          className="icon-button"
                          aria-label={`Move ${task.title} up`}
                          disabled={
                            pending ||
                            reviewedTaskIDs.has(task.id) ||
                            index === 0
                          }
                          onClick={() => void move(task, -1)}
                        >
                          <ArrowUp size={14} />
                        </button>
                        <button
                          className="icon-button"
                          aria-label={`Move ${task.title} down`}
                          disabled={
                            pending ||
                            reviewedTaskIDs.has(task.id) ||
                            index === fullOrder.length - 1
                          }
                          onClick={() => void move(task, 1)}
                        >
                          <ArrowDown size={14} />
                        </button>
                      </>
                    )}
                    {!readOnly && (
                      <button
                        className="button secondary"
                        disabled={pending || reviewedTaskIDs.has(task.id)}
                        onClick={() =>
                          void run("archiveTask", {
                            taskID: task.id,
                            archived: !task.deleted,
                          }).catch(() => {})
                        }
                      >
                        {task.deleted ? "Restore" : "Archive"}
                      </button>
                    )}
                  </div>
                </article>
              );
            })}
          </div>
        )}
        <p role="status" aria-live="polite" className="fine-print">
          {announcement}
        </p>
        <p className="task-footer-note">
          Completing or archiving a task keeps its historical calendar deadline.
          Reminders run on the Mac where you enable them. Smart planning is
          coming in a later phase.
        </p>
        {editing && (
          <Modal
            title={
              editing === "new"
                ? "New task"
                : readOnly
                  ? "Task details"
                  : "Edit task"
            }
            onClose={() => setEditing(undefined)}
          >
            <TaskEditor
              key={(editing === "new" ? "new" : editing.id) + reload}
              task={editing === "new" ? undefined : editing}
              state={state}
              token={editToken}
              readOnly={readOnly}
              onSave={async (body) => {
                await run("saveTask", body);
                setEditing(undefined);
              }}
              onReload={() => {
                if (editing === "new") {
                  setEditToken(tasks?.token || "");
                  return;
                }
                const latest = tasks?.items.find((t) => t.id === editing.id);
                if (latest) {
                  setEditing(latest);
                  setEditToken(tasks?.token || "");
                  setReload((n) => n + 1);
                }
              }}
            />
          </Modal>
        )}
      </div>
    </div>
  );
}
function TaskEditor({
  task,
  state,
  token,
  onSave,
  onReload,
  readOnly,
}: {
  task?: CalshotTask;
  state: AppState;
  token: string;
  onSave: (body: Record<string, unknown>) => Promise<void>;
  onReload: () => void;
  readOnly: boolean;
}) {
  const [title, setTitle] = useState(task?.title || "");
  const [day, setDay] = useState(task?.dueDate || "");
  const [time, setTime] = useState(task?.dueTime || "");
  const [zone, setZone] = useState(
    task?.timeZone || Intl.DateTimeFormat().resolvedOptions().timeZone,
  );
  const [notes, setNotes] = useState(task?.notes || "");
  const [reminder, setReminder] = useState(
    String(task?.reminderMinutes ?? "none"),
  );
  const [reminderTime, setReminderTime] = useState(
    task?.reminderTime || "09:00",
  );
  const [calendar, setCalendar] = useState(
    task?.calendarID || state.selectedCalendarID || "",
  );
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const remote = Boolean(
    task?.receipt && task.receiptDeviceID !== state.tasks?.deviceID,
  );
  return (
    <form
      className="task-editor"
      onSubmit={async (e) => {
        e.preventDefault();
        setSaving(true);
        setError("");
        try {
          await onSave({
            token,
            taskID: task?.id,
            title,
            dueDate: day || null,
            dueTime: time || null,
            timeZone: zone,
            notes,
            reminderMinutes: reminder === "none" ? null : Number(reminder),
            reminderTime: reminderTime || null,
            calendarID: calendar || null,
          });
        } catch (e) {
          setError((e as Error).message);
        } finally {
          setSaving(false);
        }
      }}
    >
      {error && <InlineError message={error} />}
      {remote && !readOnly && (
        <p className="notice">
          This calendar entry is linked on its source Mac. Edit its deadline
          there; you can complete or reorder this task here.
        </p>
      )}
      <label>
        Task
        <input
          autoFocus
          value={title}
          maxLength={500}
          required
          disabled={readOnly || remote}
          onChange={(e) => setTitle(e.target.value)}
        />
      </label>
      <div className="task-form-grid">
        <label>
          Due date
          <input
            type="date"
            value={day}
            disabled={readOnly || remote}
            onChange={(e) => {
              setDay(e.target.value);
              if (!e.target.value) {
                setTime("");
                setReminder("none");
              }
            }}
          />
        </label>
        <label>
          Due time (optional)
          <input
            type="time"
            value={time}
            disabled={!day || readOnly || remote}
            onChange={(e) => setTime(e.target.value)}
          />
        </label>
      </div>
      <label>
        Timezone
        <input
          value={zone}
          disabled={readOnly || remote}
          onChange={(e) => setZone(e.target.value)}
        />
      </label>
      {day && (
        <label>
          Deadline calendar
          <select
            value={calendar}
            disabled={readOnly || remote || Boolean(task?.receipt)}
            onChange={(e) => setCalendar(e.target.value)}
            required
          >
            <option value="">Choose a calendar</option>
            {task?.calendarID &&
              !state.calendars.some(
                (c) =>
                  c.id === task.calendarID && !c.isReadOnly && !c.unavailable,
              ) && (
                <option value={task.calendarID}>
                  {task.calendarName || "Source Mac calendar"}
                </option>
              )}
            {state.calendars
              .filter((c) => !c.isReadOnly && !c.unavailable)
              .map((c) => (
                <option key={c.id} value={c.id}>
                  {c.title} · {c.sourceName}
                </option>
              ))}
          </select>
        </label>
      )}
      {task?.sourceText && (
        <details>
          <summary>Source evidence</summary>
          <p className="source-text">{task.sourceText}</p>
        </details>
      )}
      <label>
        Notes
        <textarea
          value={notes}
          maxLength={8000}
          rows={3}
          disabled={readOnly || remote}
          onChange={(e) => setNotes(e.target.value)}
        />
      </label>
      <div className="task-form-grid">
        <label>
          {readOnly ? "Mac reminder" : "Remind on this Mac"}
          <select
            value={reminder}
            disabled={!day || readOnly || remote}
            onChange={(e) => setReminder(e.target.value)}
          >
            <option value="none">No reminder</option>
            <option value="0">At deadline</option>
            <option value="60">1 hour before</option>
            <option value="1440">1 day before</option>
          </select>
        </label>
        {day && !time && reminder !== "none" && (
          <label>
            Reminder time
            <input
              type="time"
              value={reminderTime}
              required
              disabled={readOnly || remote}
              onChange={(e) => setReminderTime(e.target.value)}
            />
          </label>
        )}
      </div>
      <p className="fine-print">
        {day
          ? "Your deadline is an all-day entry marked free. An exact due time stays in its title and notes. Calendar changes require review."
          : "Tasks without a due date stay in Inbox. No calendar event is created."}
      </p>
      {!readOnly && !remote && (
        <button className="button primary" disabled={saving}>
          {saving ? <Spinner /> : null}
          {day ? "Save task & review deadline" : "Save task"}
        </button>
      )}
      {error && !readOnly && (
        <button type="button" className="button secondary" onClick={onReload}>
          {task ? "Reload current task" : "Use latest task list and keep draft"}
        </button>
      )}
    </form>
  );
}
