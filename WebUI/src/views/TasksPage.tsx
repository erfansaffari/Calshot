import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  Archive,
  ArrowDown,
  ArrowUp,
  Bell,
  CalendarDays,
  Check,
  ChevronRight,
  GripVertical,
  ListTodo,
  Plus,
  RefreshCw,
} from "lucide-react";
import type { AppState, CalshotTask, Command } from "../types";
import { Empty, InlineError, Modal, Spinner } from "../components/ui";
import {
  localDay,
  reminderLabel,
  taskCounts,
  taskDueLabel,
  taskNeedsPublication,
} from "../taskPresentation";

export { taskDue, taskNeedsPublication } from "../taskPresentation";

type Filter = "all" | "today" | "upcoming" | "inbox" | "completed" | "archived";
const filters: [Filter, string][] = [
  ["all", "All"],
  ["today", "Today & overdue"],
  ["upcoming", "Upcoming"],
  ["inbox", "Inbox"],
  ["completed", "Completed"],
  ["archived", "Archived"],
];
const inFilter = (t: CalshotTask, filter: Filter, today: string) =>
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
            : true);

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
  const items = tasks?.items || [];
  const ordered = useMemo(
    () =>
      items
        .filter((t) => inFilter(t, filter, today))
        .sort((a, b) =>
          sort === "due"
            ? (a.dueDate || "9999").localeCompare(b.dueDate || "9999") ||
              a.rank - b.rank
            : a.rank - b.rank || a.id.localeCompare(b.id),
        ),
    [tasks?.items, filter, sort, today],
  );
  const counts = useMemo(
    () => ({
      all: items.filter((t) => inFilter(t, "all", today)).length,
      today: items.filter((t) => inFilter(t, "today", today)).length,
      upcoming: items.filter((t) => inFilter(t, "upcoming", today)).length,
      inbox: items.filter((t) => inFilter(t, "inbox", today)).length,
    }),
    [tasks?.items, today],
  );
  const summary = taskCounts(items, today);
  const fullOrder = items
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
  const lockReason = (task: CalshotTask) =>
    reviewedTaskIDs.has(task.id)
      ? "Finish the calendar review for this task first."
      : undefined;
  return (
    <div className="page-scroll">
      <div className="page-inner tasks-page">
        <header className="page-title tasks-head">
          <div className="tasks-heading">
            <h1>Tasks</h1>
            {tasks?.loaded && (
              <p className="tasks-summary">
                <span>
                  {summary.open === 0 ? "Nothing open" : `${summary.open} open`}
                </span>
                {summary.overdue > 0 && (
                  <>
                    {" · "}
                    <span className="task-overdue">
                      {summary.overdue} overdue
                    </span>
                  </>
                )}
                {summary.dueToday > 0 && (
                  <>
                    {" · "}
                    <span>{summary.dueToday} due today</span>
                  </>
                )}
              </p>
            )}
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
        <p role="status" aria-live="polite" className="task-live">
          {announcement}
        </p>
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
              Added as all-day, free entries above the timetable. Exact due
              times stay in the title and notes.
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
            {filters.map(([id, label]) => {
              const count = counts[id as keyof typeof counts];
              return (
                <button
                  key={id}
                  aria-pressed={filter === id}
                  onClick={() => setFilter(id)}
                >
                  {label}
                  {count > 0 && (
                    <span className="task-count" aria-hidden="true">
                      {count}
                    </span>
                  )}
                </button>
              );
            })}
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
          <div className="tasks-empty-state">
            <Empty
              icon={<ListTodo size={24} />}
              title={
                filter === "all" ? "No tasks yet" : "No tasks in this view"
              }
            >
              {filter === "all"
                ? "A title is enough. Add a deadline when you know it."
                : "Your other tasks are in All."}
            </Empty>
          </div>
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
              const confirmed = !needs && Boolean(task.receipt);
              const due = taskDueLabel(task, today);
              const locked = reviewedTaskIDs.has(task.id);
              return (
                <article
                  className={
                    "task-row" +
                    (task.completed ? " task-completed" : "") +
                    (canMove ? " task-draggable" : "")
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
                  {canMove && (
                    <span className="task-grip" aria-hidden="true">
                      <GripVertical size={14} />
                    </span>
                  )}
                  <input
                    type="checkbox"
                    aria-label={
                      (task.completed ? "Reopen " : "Complete ") + task.title
                    }
                    title={lockReason(task)}
                    checked={task.completed}
                    disabled={pending || readOnly || task.deleted || locked}
                    onChange={(e) =>
                      void run("completeTask", {
                        taskID: task.id,
                        completed: e.target.checked,
                      }).catch(() => {})
                    }
                  />
                  <div className="task-body">
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
                      <span className={due.overdue ? "task-overdue" : ""}>
                        <CalendarDays size={12} />
                        {due.text}
                      </span>
                      {task.reminderMinutes != null && (
                        <span>
                          <Bell size={12} />
                          {reminderLabel(task.reminderMinutes)}
                          {task.reminderDeviceID !== tasks.deviceID &&
                            " · source Mac"}
                        </span>
                      )}
                      {task.sourceLink ? (
                        <span>Linked to source · {task.sourceLink.calendarName} · {task.sourceLink.sourceName}{task.sourceLink.deviceID !== tasks.deviceID ? " · source Mac" : " · this Mac"}</span>
                      ) : confirmed ? (
                        <span className="task-ok">
                          <Check size={12} />
                          On{" "}
                          {task.receipt?.calendarName ||
                            task.calendarName ||
                            "calendar"}
                        </span>
                      ) : (
                        <>
                          {task.calendarName && (
                            <span>{task.calendarName}</span>
                          )}
                          {needs && !task.calendarError && (
                            <span className="task-pending">
                              {task.receipt
                                ? "Deadline change needs review"
                                : "Not on calendar yet"}
                            </span>
                          )}
                        </>
                      )}
                    </div>
                    {task.calendarError && (
                      <p className="task-row-error" role="alert">
                        {task.calendarError}
                      </p>
                    )}
                  </div>
                  <div className="task-actions">
                    {needs && !readOnly && !task.completed && !task.deleted && (
                      <button
                        className="button secondary"
                        disabled={pending || locked}
                        title={lockReason(task)}
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
                          title="Move up"
                          disabled={pending || locked || index === 0}
                          onClick={() => void move(task, -1)}
                        >
                          <ArrowUp size={14} />
                        </button>
                        <button
                          className="icon-button"
                          aria-label={`Move ${task.title} down`}
                          title="Move down"
                          disabled={
                            pending || locked || index === fullOrder.length - 1
                          }
                          onClick={() => void move(task, 1)}
                        >
                          <ArrowDown size={14} />
                        </button>
                      </>
                    )}
                    {!readOnly &&
                      (task.deleted ? (
                        <button
                          className="button secondary"
                          disabled={pending || locked}
                          onClick={() =>
                            void run("archiveTask", {
                              taskID: task.id,
                              archived: false,
                            }).catch(() => {})
                          }
                        >
                          Restore
                        </button>
                      ) : (
                        <button
                          className="icon-button"
                          aria-label={`Archive ${task.title}`}
                          title="Archive"
                          disabled={pending || locked}
                          onClick={() =>
                            void run("archiveTask", {
                              taskID: task.id,
                              archived: true,
                            }).catch(() => {})
                          }
                        >
                          <Archive size={14} />
                        </button>
                      ))}
                  </div>
                </article>
              );
            })}
          </div>
        )}
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
              onCancel={() => setEditing(undefined)}
              onSave={async (body) => {
                await run("saveTask", body);
                setAnnouncement("Saved “" + String(body.title) + "” to Tasks.");
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
  onCancel,
  readOnly,
}: {
  task?: CalshotTask;
  state: AppState;
  token: string;
  onSave: (body: Record<string, unknown>) => Promise<void>;
  onReload: () => void;
  onCancel: () => void;
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
  const [intentChoice, setIntentChoice] = useState<"none" | "new" | undefined>();
  const linked = Boolean(task?.sourceLink || task?.calendarIntent === "existing");
  const intent = linked ? "existing" : intentChoice ?? (task?.intentProvenance === "suppressed" ? "none" : task?.calendarIntent === "none" && task.intentProvenance === "defaulted" ? "new" : task?.calendarIntent ?? "new");
  const publishes = intent === "new";
  const [more, setMore] = useState(
    readOnly || Boolean(task?.notes) || task?.reminderMinutes != null,
  );
  const [error, setError] = useState("");
  const [titleError, setTitleError] = useState("");
  const titleRef = useRef<HTMLInputElement>(null);
  const [saving, setSaving] = useState(false);
  const remote = Boolean(
    task?.receipt && task.receiptDeviceID !== state.tasks?.deviceID,
  );
  const locked = readOnly || remote;
  return (
    <form
      className="task-editor"
      noValidate
      onSubmit={async (e) => {
        e.preventDefault();
        setError("");
        if (!title.trim()) {
          setTitleError("Enter a task title.");
          titleRef.current?.focus();
          return;
        }
        if (locked || saving) return;
        if (day && publishes && !calendar) {
          setError("Choose a calendar for the deadline.");
          return;
        }
        if (day && time === "" && reminder !== "none" && !reminderTime) {
          setMore(true);
          setError("Choose a time for the reminder.");
          return;
        }
        setSaving(true);
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
            ...(publishes && !task?.receipt ? { calendarID: calendar || null } : {}),
            ...(intentChoice == null ? {} : { calendarIntent: intentChoice }),
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
        <p className="notice task-editor-notice">
          This calendar entry is linked on its source Mac. Edit its deadline
          there; you can complete or reorder this task here.
        </p>
      )}
      <label>
        Task
        <input
          ref={titleRef}
          autoFocus
          value={title}
          maxLength={500}
          aria-required="true"
          aria-invalid={Boolean(titleError)}
          aria-describedby={titleError ? "task-title-error" : undefined}
          disabled={locked}
          onChange={(e) => {
            setTitle(e.target.value);
            if (titleError && e.target.value.trim()) setTitleError("");
          }}
        />
      </label>
      {titleError && (
        <div id="task-title-error">
          <InlineError message={titleError} />
        </div>
      )}
      <div className="task-form-grid">
        <label>
          Due date
          <input
            type="date"
            value={day}
            disabled={locked}
            onChange={(e) => {
              setDay(e.target.value);
              if (!e.target.value) {
                setTime("");
                setReminder("none");
              }
            }}
          />
        </label>
        {day && (
          <label>
            Due time (optional)
            <input
              type="time"
              value={time}
              disabled={locked}
              onChange={(e) => setTime(e.target.value)}
            />
          </label>
        )}
        {day && time && (
          <label>
            Timezone
            <input
              value={zone}
              disabled={locked}
              onChange={(e) => setZone(e.target.value)}
            />
          </label>
        )}
      </div>
      {!linked && !task?.receipt && (
        <label>
          Calendar use
          <select value={intent} disabled={locked} onChange={(e) => setIntentChoice(e.target.value as "none" | "new")}>
            <option value="none">Tasks only</option>
            <option value="new">Publish deadline</option>
          </select>
        </label>
      )}
      {linked && <p className="fine-print">Linked to source · {task?.sourceLink?.calendarName || "calendar"}. Edits change this task only; the source event stays unchanged.{task?.sourceLink?.deviceID !== state.tasks?.deviceID ? " Source details belong to the source Mac." : " This link belongs to this Mac."}</p>}
      {task?.receipt && <p className="fine-print">This task owns a published deadline. Changing to Tasks only requires a choice to retain or remove that entry; that transition is not available here yet.</p>}
      {day && publishes && (
        <label>
          Deadline calendar
          <select
            value={calendar}
            disabled={locked || Boolean(task?.receipt)}
            onChange={(e) => setCalendar(e.target.value)}
            aria-required="true"
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
      <button
        type="button"
        className="task-more"
        aria-expanded={more}
        aria-controls="task-more-fields"
        onClick={() => setMore(!more)}
      >
        <ChevronRight size={14} />
        Notes{day ? " & reminder" : ""}
      </button>
      {more && (
        <div className="task-more-fields" id="task-more-fields">
          <label>
            Notes
            <textarea
              value={notes}
              maxLength={8000}
              rows={3}
              disabled={locked}
              onChange={(e) => setNotes(e.target.value)}
            />
          </label>
          {day && (
            <div className="task-form-grid">
              <label>
                {readOnly ? "Mac reminder" : "Remind on this Mac"}
                <select
                  value={reminder}
                  disabled={locked}
                  onChange={(e) => setReminder(e.target.value)}
                >
                  <option value="none">No reminder</option>
                  <option value="0">At deadline</option>
                  <option value="60">1 hour before</option>
                  <option value="1440">1 day before</option>
                </select>
              </label>
              {!time && reminder !== "none" && (
                <label>
                  Reminder time
                  <input
                    type="time"
                    value={reminderTime}
                    disabled={locked}
                    onChange={(e) => setReminderTime(e.target.value)}
                  />
                </label>
              )}
            </div>
          )}
        </div>
      )}
      {task?.sourceText && (
        <details>
          <summary>Source evidence</summary>
          <p className="source-text">{task.sourceText}</p>
        </details>
      )}
      <p className="fine-print">
        {linked
          ? "Task edits never change the linked source event."
          : !publishes
            ? "Tasks only. No calendar entry is created."
            : day
          ? "Adds one all-day, free entry to your calendar after you review it. An exact time stays in the title and notes."
          : "No date: stays in Inbox and adds nothing to your calendar."}
        {task?.receipt &&
          " Completing or archiving keeps its calendar deadline."}
      </p>
      <div className="task-editor-foot">
        {error && !readOnly && (
          <button type="button" className="button secondary" onClick={onReload}>
            {task
              ? "Reload current task"
              : "Use latest task list and keep draft"}
          </button>
        )}
        <span className="task-foot-spacer" />
        <button type="button" className="button secondary" onClick={onCancel}>
          {readOnly || remote ? "Close" : "Cancel"}
        </button>
        {!readOnly && !remote && (
          <button className="button primary" disabled={saving}>
            {saving ? <Spinner /> : null}
            {day && publishes ? "Save task & review deadline" : "Save task"}
          </button>
        )}
      </div>
    </form>
  );
}
