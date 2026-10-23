import type { CalshotTask } from "./types";

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

export const localDay = (date = new Date()) =>
  `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;

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

/** Concise due text for dense rows. Overdue is stated in words, not only color. */
export function taskDueLabel(task: CalshotTask, today = localDay()) {
  if (!task.dueDate) return { text: "No date", overdue: false };
  const day = new Date(task.dueDate + "T12:00:00");
  const next = new Date(today + "T12:00:00");
  next.setDate(next.getDate() + 1);
  const overdue = !task.completed && task.dueDate < today;
  let date =
    task.dueDate === today
      ? "Today"
      : task.dueDate === localDay(next)
        ? "Tomorrow"
        : day.toLocaleDateString(undefined, {
            month: "short",
            day: "numeric",
            ...(day.getFullYear() !== Number(today.slice(0, 4))
              ? { year: "numeric" }
              : {}),
          });
  if (overdue) date = "Overdue · " + date;
  if (!task.dueTime) return { text: date, overdue };
  const [h, m] = task.dueTime.split(":").map(Number);
  const time = new Date(2000, 0, 1, h, m).toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  return {
    text:
      date + ", " + time + (task.timeZone && task.timeZone !== zone ? " (" + task.timeZone + ")" : ""),
    overdue,
  };
}

export function reminderLabel(minutes: number) {
  return minutes === 0
    ? "At deadline"
    : minutes === 60
      ? "1 hour before"
      : minutes === 1440
        ? "1 day before"
        : minutes + " min before";
}

export function taskCounts(items: CalshotTask[], today = localDay()) {
  const open = items.filter((t) => !t.deleted && !t.completed);
  return {
    open: open.length,
    overdue: open.filter((t) => t.dueDate && t.dueDate < today).length,
    dueToday: open.filter((t) => t.dueDate === today).length,
  };
}

/** Next open tasks for the Assistant home: overdue, today, upcoming, then undated. */
export function nextTasks(items: CalshotTask[], today = localDay(), limit = 3) {
  const bucket = (t: CalshotTask) =>
    !t.dueDate ? 3 : t.dueDate < today ? 0 : t.dueDate === today ? 1 : 2;
  return items
    .filter((t) => !t.deleted && !t.completed)
    .sort(
      (a, b) =>
        bucket(a) - bucket(b) ||
        (a.dueDate || "").localeCompare(b.dueDate || "") ||
        a.rank - b.rank ||
        a.id.localeCompare(b.id),
    )
    .slice(0, limit);
}
