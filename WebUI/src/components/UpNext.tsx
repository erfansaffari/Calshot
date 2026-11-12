import { useEffect, useState } from "react";
import { ArrowUpRight, CalendarDays, Circle, RefreshCw } from "lucide-react";
import type { AppState, CalendarEvent, CalshotTask } from "../types";
import { command } from "../bridge";
import { dateKey, useCalendarNavigation } from "../calendarPresentation";
import { deadlineMarker, isAllDayEvent, zoneDayKey, keyToDate } from "../calendarEvents";
import { requestTaskEditor, taskDueLabel } from "../taskPresentation";
import { Spinner } from "./ui";
import { RecentChanges } from "./RecentChanges";

export function upcomingEvents(events: CalendarEvent[], now: Date) {
  const seen = new Set<string>();
  return events.filter(e => {
    const key = `${e.calendarIdentifier}|${e.eventIdentifier}|${e.start}`;
    if (seen.has(key) || !Number.isFinite(Date.parse(e.start)) || Date.parse(e.end) <= +now || deadlineMarker(e.notes)) return false;
    seen.add(key); return true;
  }).sort((a, b) => {
    // Timed appointments come before all-day reminders on the same day.
    const day = dateKey(new Date(a.start)).localeCompare(dateKey(new Date(b.start)));
    return day || Number(isAllDayEvent(a)) - Number(isAllDayEvent(b)) || Date.parse(a.start) - Date.parse(b.start);
  });
}
export function upcomingTasks(items: CalshotTask[], now: Date) {
  const end = new Date(now); end.setDate(end.getDate() + 7);
  const priority = (t: CalshotTask) => !t.dueDate ? 2 : t.dueDate < zoneDayKey(+now, t.timeZone) ? 1 : 0;
  return items.filter(t => !t.completed && !t.deleted && (!t.dueDate || t.dueDate < zoneDayKey(+end, t.timeZone)))
    .sort((a,b) => priority(a) - priority(b) || (priority(a) === 1 ? (b.dueDate || "").localeCompare(a.dueDate || "") : (a.dueDate || "9999").localeCompare(b.dueDate || "9999")) || (a.dueTime || "23:59").localeCompare(b.dueTime || "23:59") || a.rank - b.rank);
}
function dayLabel(date: Date, now: Date) {
  const tomorrow = new Date(now); tomorrow.setDate(tomorrow.getDate() + 1);
  return dateKey(date) === dateKey(now) ? "Today" : dateKey(date) === dateKey(tomorrow) ? "Tomorrow" : date.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}
export function UpNext({ state, onAction }: { state: AppState; onAction: (action: string, extra?: Record<string, unknown>) => Promise<void> }) {
  const calendar = useCalendarNavigation();
  const [now, setNow] = useState(() => new Date());
  const [retry, setRetry] = useState(0);
  const [pending, setPending] = useState(true);
  const [error, setError] = useState("");
  const day = dateKey(now), refreshWindow = Math.floor(+now / 300000);
  const start = new Date(now); start.setHours(0,0,0,0);
  const end = new Date(start); end.setDate(end.getDate()+7);
  const startISO = start.toISOString(), endISO = end.toISOString();
  const sharingKey = JSON.stringify(state.sharing?.shares.map(s => [s.id, s.status, s.permission, s.calendars.map(c => [c.id, c.syncedAt, c.stale, c.error])]) || []);
  const ids = JSON.stringify(state.calendars.map(c => c.id).sort());
  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), 60000);
    return () => clearInterval(timer);
  }, []);
  useEffect(() => {
    let current = true;
    setPending(true); setError("");
    void command({ action: "loadCalendarEvents", start: startISO, end: endISO, calendarIDs: JSON.parse(ids) })
      .catch(e => { if(current) setError(e.message); })
      .finally(() => { if(current) setPending(false); });
    return () => { current = false; };
  }, [ids, sharingKey, day, refreshWindow, retry, state.calendarContentToken, state.auth?.userID]);
  const view = state.calendarView;
  // Keep showing the last result while it refreshes; only an empty first load says "Checking".
  const matches = view?.loaded && Date.parse(view.start || "") === +start && Date.parse(view.end || "") === +end;
  const loading = !matches && !error;
  const events = matches ? upcomingEvents(view.events, now).filter(e => Date.parse(e.start) < +end) : [];
  const tasks = upcomingTasks(state.tasks?.items || [], now);
  const issues = matches ? view.errors : [];
  const displayDate = (event: CalendarEvent) => Date.parse(event.start) <= +now ? new Date(now) : isAllDayEvent(event) ? keyToDate(zoneDayKey(Date.parse(event.start), event.timeZone)) : new Date(event.start);
  const openCalendar = (event?: CalendarEvent) => {
    calendar?.setAnchor(event ? displayDate(event) : new Date()); calendar?.setMode("day");
    void onAction("navigate", { page: "calendars" });
  };
  return <section className="up-next" aria-label="Up next">
    <div className="up-next-heading"><h2>Up next</h2><span>Next 7 days</span><button className="icon-button" aria-label="Refresh upcoming events" aria-busy={pending || undefined} disabled={pending} onClick={() => setRetry(v => v+1)}><RefreshCw size={13} /></button></div>
    <div className="up-next-scroll" tabIndex={0} aria-label="Upcoming events and tasks">
      <div className="up-next-section-heading"><h3>Events</h3><button className="icon-button" aria-label="Open calendar" onClick={() => openCalendar()}><ArrowUpRight size={13} /></button></div>
      {state.calendars.length === 0 ? <p className="up-next-empty">Connect a calendar to see what’s next.</p> : loading ? <p className="up-next-empty" role="status"><Spinner /> Checking your calendars…</p> : !events.length && !error && !issues.length ? <p className="up-next-empty">No upcoming events in the next 7 days.</p> : null}
      {error && <p className="up-next-issue" role="alert">Events couldn’t refresh. {error}</p>}
      {!loading && issues.length > 0 && <details className="up-next-issue"><summary>Some calendars couldn’t be checked</summary>{issues.map((e,i) => <p key={i}>{e.calendarName}: {e.message}</p>)}</details>}
      {matches && view.truncated && <p className="up-next-issue">More events may be missing from this preview.</p>}
      {events.slice(0,3).map((e, index) => {
        const ongoing = Date.parse(e.start) <= +now && !isAllDayEvent(e);
        const date = displayDate(e);
        return <button className="up-next-row" data-secondary={index > 0 || undefined} key={`${e.calendarIdentifier}|${e.eventIdentifier}|${e.start}`} onClick={() => openCalendar(e)} title={`${e.title} · ${e.calendarName} · ${e.sourceName} · ${new Date(e.start).toLocaleString()} – ${new Date(e.end).toLocaleString()}`}>
          <CalendarDays size={14} aria-hidden /><span><strong>{e.title}</strong><span className={ongoing ? "up-next-now" : ""}>{ongoing ? "Now" : dayLabel(date, now)} · {isAllDayEvent(e) ? "All day" : date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</span><small>{e.calendarName} · {e.sourceName}</small></span>
        </button>;
      })}
      <div className="up-next-section-heading"><h3>Tasks</h3><button className="icon-button" aria-label="Open tasks" onClick={() => void onAction("navigate", { page: "tasks" })}><ArrowUpRight size={13} /></button></div>
      {!state.tasks?.loaded ? <p className="up-next-empty">{state.tasks?.error ? "Tasks couldn’t be loaded. Open Tasks to retry." : "Loading your tasks…"}</p> : !tasks.length ? <p className="up-next-empty">No tasks due this week.</p> : tasks.slice(0,3).map((t, index) => {
        const due = taskDueLabel(t, zoneDayKey(+now, t.timeZone));
        return <button className="up-next-row" data-secondary={index > 0 || undefined} key={t.id} title={`${t.title} · ${due.text}`} onClick={() => { requestTaskEditor(t.id); if (state.page !== "tasks") void onAction("navigate", { page: "tasks" }); }}><Circle size={14} aria-hidden /><span><strong>{t.title}</strong><span className={due.overdue ? "up-next-overdue" : ""}>{due.text}</span></span></button>;
      })}
      {state.tasks?.loaded && state.tasks.error && <p className="up-next-issue">Task sync needs attention. Local tasks are shown.</p>}
      <RecentChanges changes={state.recentChanges} since={+now - 86400000} limit={3} heading="Recently done" />
    </div>
  </section>;
}
