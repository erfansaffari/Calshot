// Alert labels shared by Settings and review rows; they mirror the native EventAlerts labels.

/** "10 min before", "1 hour before", "1 day before", "At start" — mirrors the native labels. */
export function alertLeadLabel(minutes: number, kind: "event" | "task" = "event") {
  if (minutes === 0) return kind === "task" ? "At due time" : "At start";
  const unit = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
  const text = minutes % 10080 === 0 ? unit(minutes / 10080, "week", "weeks")
    : minutes % 1440 === 0 ? unit(minutes / 1440, "day", "days")
    : minutes % 60 === 0 ? unit(minutes / 60, "hour", "hours")
    : minutes > 60 ? `${Math.floor(minutes / 60)} h ${minutes % 60} min` : `${minutes} min`;
  return minutes < 0 ? `${text.replace("-", "")} after start` : `${text} before`;
}

const timedChoices = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080];
/** All-day alerts count from midnight: 900 is 9 AM the day before. */
const allDayChoices: [number, string][] = [[900, "Day before at 9 AM"], [2340, "2 days before at 9 AM"], [9540, "1 week before at 9 AM"]];
/** One-alert choices for the event editors, labelled for timed or all-day events. */
export function alertChoices(allDay: boolean): [number, string][] {
  return allDay ? allDayChoices : timedChoices.map((m) => [m, alertLeadLabel(m)]);
}

/** Alerts on an event: "Calendar default", "None" or "10 min before, 1 hour before". */
export function alertSummary(minutes?: number[] | null) {
  if (minutes == null) return "Calendar default";
  return minutes.length === 0 ? "None" : minutes.map((m) => alertLeadLabel(m)).join(", ");
}
