import { friendCalendars } from "../types";
import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import {
  CalendarDays,
  ChevronLeft,
  ChevronRight,
  RefreshCw,
  MapPin,
  Clock,
  Sparkles,
  Plus,
  ArrowUp,
  Pencil,
  Trash2,
} from "lucide-react";
import { useCalendarSwipe } from "../useCalendarSwipe";
import type { AppState, CalendarEvent, Command } from "../types";
import {
  Badge,
  Empty,
  InlineError,
  Modal,
  Spinner,
  timeRange,
} from "../components/ui";
import {
  eventInfo,
  isAllDayEvent,
  keyToDate,
  occursOn,
  zoneDayKey,
} from "../calendarEvents";
import {
  calendarColor,
  dateKey,
  monthDays,
  useCalendar,
} from "../calendarPresentation";
import { deadlineTaskID, duplicatePrefix, requestTaskEditor } from "../taskPresentation";

export const dayKey = dateKey;
export { occursOn };
const dueLabel = (time: string) => {
  const [hour, minute] = time.split(":").map(Number);
  return new Date(2026, 0, 1, hour, minute).toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
};
const labelDay = (date: Date) =>
  date.toLocaleDateString(undefined, { dateStyle: "full" });
const eventKey = (event: CalendarEvent) =>
  event.calendarIdentifier + event.eventIdentifier + event.start;
const minuteOfDay = (date: Date) => date.getHours() * 60 + date.getMinutes();
function localTime(value: string, zone?: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: zone || undefined,
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(value));
  const get = (name: string) =>
    parts.find((part) => part.type === name)?.value || "00";
  return `${get("hour")}:${get("minute")}`;
}
export function dayInterval(event: CalendarEvent, day: Date) {
  const next = new Date(day);
  next.setDate(next.getDate() + 1);
  const start = new Date(event.start),
    end = new Date(event.end);
  const from = start <= day ? 0 : minuteOfDay(start);
  return {
    from,
    to: Math.max(from + 1, end >= next ? 1440 : minuteOfDay(end)),
  };
}
// Assign lanes to each connected overlap group, including the minimum hit area
// of short events. Back-to-back events can reuse a lane; transitive overlaps
// share the group's maximum lane count rather than covering one another.
export function layoutDayEvents(events: CalendarEvent[], day: Date) {
  const sorted = events
    .filter((e) => !isAllDayEvent(e) && occursOn(e, day))
    .map((event) => ({ event, ...dayInterval(event, day), lane: 0, lanes: 1 }))
    .sort(
      (a, b) =>
        a.from - b.from ||
        b.to - a.to ||
        eventKey(a.event).localeCompare(eventKey(b.event)),
    );
  let group: typeof sorted = [],
    ends: number[] = [],
    groupEnd = -1;
  const finish = () => {
    for (const item of group) item.lanes = ends.length;
    group = [];
    ends = [];
  };
  for (const item of sorted) {
    if (item.from >= groupEnd) {
      finish();
      groupEnd = -1;
    }
    const lane = ends.findIndex((end) => end <= item.from);
    item.lane = lane < 0 ? ends.length : lane;
    const renderedEnd = Math.max(item.to, item.from + 28);
    ends[item.lane] = renderedEnd;
    groupEnd = Math.max(groupEnd, renderedEnd);
    group.push(item);
  }
  finish();
  return sorted;
}

export function CalendarPage({
  state,
  onCommand: command,
  readOnly = false,
}: {
  state: AppState;
  onCommand: (message: Command) => Promise<void>;
  readOnly?: boolean;
}) {
  const { anchor, setAnchor, mode, setMode, hidden } = useCalendar();
  const [detailKey, setDetailKey] = useState<string>();
  const [linkErrors, setLinkErrors] = useState<Record<string, string>>({});
  const [linking, setLinking] = useState(false);
  const linkInFlight = useRef(false);
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [ask, setAsk] = useState("");
  const [askSelection, setAskSelection] = useState<{ eventHandle: string; viewToken: string }>();
  const [sending, setSending] = useState(false);
  const [newEvent, setNewEvent] = useState(false);
  const [editingEvent, setEditingEvent] = useState<CalendarEvent>();
  const [deletingEvent, setDeletingEvent] = useState<CalendarEvent>();
  const [now, setNow] = useState(() => new Date());
  const scroller = useRef<HTMLDivElement>(null);
  const board = useRef<HTMLDivElement>(null);
  const monthYear = `${anchor.getFullYear()}-${anchor.getMonth()}`;
  const rangeKey = `${mode}-${dayKey(anchor)}`;
  const range = useMemo(() => {
    if (mode !== "month") {
      const start = new Date(anchor);
      if (mode === "week") start.setDate(start.getDate() - start.getDay());
      const end = new Date(start);
      end.setDate(end.getDate() + (mode === "week" ? 7 : 1));
      return { start, end, days: monthDays(anchor) };
    }
    const days = monthDays(anchor),
      end = new Date(days[0]);
    end.setDate(end.getDate() + 42);
    return { start: days[0], end, days };
  }, [rangeKey]);
  const visibleSources = [...state.calendars, ...friendCalendars(state)];
  const sharingAccess = JSON.stringify(state.sharing?.shares.map(s => [s.id, s.permission, s.status, s.calendars.map(c => c.id)]) || []);
  const ids = visibleSources
    .filter((c) => !hidden.has(c.id))
    .map((c) => c.id)
    .sort();
  const idsKey = JSON.stringify(ids);
  useEffect(() => {
    let current = true;
    setPending(true);
    setError("");
    void command({
      action: "loadCalendarEvents",
      start: range.start.toISOString(),
      end: range.end.toISOString(),
      calendarIDs: JSON.parse(idsKey),
    })
      .catch((e) => {
        if (current) setError(e.message);
      })
      .finally(() => {
        if (current) setPending(false);
      });
    return () => {
      current = false;
    };
  }, [range, idsKey, refresh, sharingAccess, state.sharing?.error]);
  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), 60000);
    return () => clearInterval(timer);
  }, []);
  const view = state.calendarView;
  const loading = pending || Boolean(view?.loading);
  const matches = Boolean(
    view?.loaded &&
    view.start &&
    new Date(view.start).getTime() === range.start.getTime() &&
    new Date(view.end!).getTime() === range.end.getTime(),
  );
  const events = matches
    ? (view?.events || [])
        .filter((e) => ids.includes(e.calendarIdentifier))
        .sort(
          (a, b) =>
            Number(isAllDayEvent(b)) - Number(isAllDayEvent(a)) ||
            a.start.localeCompare(b.start) ||
            a.title.localeCompare(b.title),
        )
    : [];
  const errors = [
    ...(matches ? (view?.errors || []).filter((e) => ids.includes(e.calendarIdentifier)) : []),
    ...(state.sharing?.error ? [{ calendarIdentifier: "shared:status", calendarName: "Friend calendars", message: state.sharing.error }] : []),
  ];
  const detail = events.find((e) => eventKey(e) === detailKey);
  const detailInfo = detail ? eventInfo(detail) : undefined;
  const detailCalendar = detail
    ? state.calendars.find((c) => c.id === detail.calendarIdentifier)
    : undefined;
  const canChange = Boolean(
    detail &&
      !readOnly &&
      !detail.calendarIdentifier.startsWith("shared:") &&
      detailCalendar &&
      !detailCalendar.isReadOnly &&
      !detailCalendar.unavailable,
  );
  const canDirectChange = Boolean(
    canChange && detail?.selectionHandle && detail.selectionGeneration,
  );
  // A task's own deadline entry is changed through the task, so both stay in step.
  const detailTaskID = deadlineTaskID(detail?.notes);
  const deadlineTask = detailTaskID
    ? state.tasks?.items.find((t) => t.id.toLowerCase() === detailTaskID)
    : undefined;
  // Your own edits wait only for a save in progress; an open conversation doesn't block them.
  const writeBusy = state.saving;
  const changeSaved = () => setRefresh((n) => n + 1);
  const openTask = (id: string) => {
    requestTaskEditor(id);
    void command({ action: "navigate", page: "tasks" }).catch((e) => setError(e.message));
  };
  const taskNotice = detail?.selectionHandle ? state.calendarTaskNotices?.[detail.selectionHandle] : undefined;
  const canLink = Boolean(!readOnly && detail?.selectionHandle && detail.selectionGeneration && detailCalendar && !detailCalendar.unavailable && !detail?.calendarIdentifier.startsWith("shared:"));
  const linkSelected = async () => {
    if (!detail || !canLink || linkInFlight.current) return;
    const handle = detail.selectionHandle!;
    linkInFlight.current = true;
    setLinking(true);
    setLinkErrors((old) => ({ ...old, [handle]: "" }));
    try {
      await command({ action: "linkCalendarEventTask", selectionHandle: handle, selectionGeneration: detail.selectionGeneration });
    } catch (e) {
      setLinkErrors((old) => ({ ...old, [handle]: (e as Error).message }));
    } finally {
      linkInFlight.current = false;
      setLinking(false);
    }
  };
  const askAbout = (text: string) => {
    setAskSelection(detail?.selectionHandle && detail.selectionGeneration ? { eventHandle: detail.selectionHandle, viewToken: detail.selectionGeneration } : undefined);
    setAsk(text);
    setDetailKey(undefined);
    requestAnimationFrame(() =>
      document
        .querySelector<HTMLInputElement>(".calendar-ask input")
        ?.focus(),
    );
  };
  useEffect(() => {
    if (askSelection && !events.some((event) => event.selectionHandle === askSelection.eventHandle && event.selectionGeneration === askSelection.viewToken)) {
      setAskSelection(undefined);
      setAsk("");
    }
  }, [view, idsKey]);
  const color = (id: string) =>
    calendarColor(visibleSources.findIndex((c) => c.id === id));
  const tint = (event: CalendarEvent) =>
    ({ "--event-color": color(event.calendarIdentifier) }) as CSSProperties;
  const weekStart = new Date(anchor);
  weekStart.setDate(weekStart.getDate() - weekStart.getDay());
  const days =
    mode === "day"
      ? [anchor]
      : Array.from(
          { length: 7 },
          (_, i) =>
            new Date(
              weekStart.getFullYear(),
              weekStart.getMonth(),
              weekStart.getDate() + i,
            ),
        );
  const timed = days.flatMap((day) =>
    events
      .filter((e) => !isAllDayEvent(e) && occursOn(e, day))
      .map((e) => dayInterval(e, day)),
  );
  // Match the reference's 8 AM–8 PM window, expanding for early/late events.
  const firstHour = Math.min(8, ...timed.map((e) => Math.floor(e.from / 60)));
  const lastHour = Math.max(20, ...timed.map((e) => Math.ceil(e.to / 60)));
  const hourHeight = 52,
    gridHeight = (lastHour - firstHour) * hourHeight;
  const hours = Array.from(
    { length: lastHour - firstHour + 1 },
    (_, i) => firstHour + i,
  );
  const columns = {
    gridTemplateColumns: `52px repeat(${days.length}, minmax(0, 1fr))`,
  };
  useEffect(() => {
    if (scroller.current)
      scroller.current.scrollTop =
        firstHour < 8 ? (8 - firstHour) * hourHeight : 0;
  }, [mode, dayKey(anchor), firstHour]);
  const blocked =
    state.running ||
    state.saving ||
    state.waitingApproval ||
    state.proposals.some((proposal) => !proposal.isFinished) ||
    Boolean(state.question) ||
    state.isCapturing ||
    state.isRecognizing;
  const changeRange = (offset: number) => {
    setDetailKey(undefined);
    const next = new Date(anchor);
    if (mode === "month")
      setAnchor(new Date(anchor.getFullYear(), anchor.getMonth() + offset, 1));
    else {
      next.setDate(next.getDate() + offset * (mode === "week" ? 7 : 1));
      setAnchor(next);
    }
  };
  const openSettings = () =>
    void command({
      action: "navigate",
      page: "settings",
      section: "calendars",
    }).catch((e) => setError(e.message));
  useCalendarSwipe(board, changeRange, visibleSources.length > 0);
  const send = async (text: string) => {
    if (blocked)
      throw new Error(
        "Finish or stop the current task in Assistant before starting another.",
      );
    if (!text.trim() || sending) return;
    setSending(true);
    setError("");
    try {
      await command({ action: "startCalendarTask", text: text.trim(), ...(newEvent ? {} : askSelection || {}) });
      setAskSelection(undefined);
      setAsk("");
      setNewEvent(false);
      setDetailKey(undefined);
    } catch (e) {
      setError((e as Error).message);
      throw e;
    } finally {
      setSending(false);
    }
  };
  const eventLabel = (event: CalendarEvent) =>
    `${event.title || "Untitled event"}, ${timeRange(event.start, event.end, undefined, isAllDayEvent(event))}, ${event.calendarName}`;
  // Week cells stay compact: three entries, then a link into Day for the rest.
  const allDayLimit = mode === "week" ? 3 : Infinity;
  const allDayByDay = days.map((day) =>
    events.filter((e) => isAllDayEvent(e) && occursOn(e, day)),
  );
  const allDayRows = Math.max(
    1,
    ...allDayByDay.map(
      (items) => Math.min(items.length, allDayLimit) + Number(items.length > allDayLimit),
    ),
  );
  return (
    <div className="calendar-page">
      <header className="calendar-toolbar">
        <h1>
          {anchor.toLocaleDateString(undefined, { month: "long" })}{" "}
          <span>{anchor.getFullYear()}</span>
        </h1>
        <div className="calendar-range-buttons">
          <button
            className="icon-button"
            aria-label={`Previous ${mode}`}
            onClick={() => changeRange(-1)}
          >
            <ChevronLeft size={15} />
          </button>
          <button
            className="icon-button"
            aria-label={`Next ${mode}`}
            onClick={() => changeRange(1)}
          >
            <ChevronRight size={15} />
          </button>
        </div>
        <button
          className="button secondary calendar-today"
          onClick={() => {
            const date = new Date();
            date.setHours(0, 0, 0, 0);
            setAnchor(date);
          }}
        >
          Today
        </button>
        {readOnly ? (
          <a className="button secondary calendar-ask" href="calshot://">
            Ask Calshot in the Mac app ↗
          </a>
        ) : (
          <form
            className="calendar-ask"
            onSubmit={(e) => {
              e.preventDefault();
              void send(ask).catch(() => {});
            }}
          >
            <Sparkles size={14} />
            <input
              aria-label="Ask Calshot about your calendar"
              placeholder={friendCalendars(state).length ? "Ask about your calendar or a friend’s…" : "Ask about your calendar…"}
              value={ask}
              maxLength={8000}
              onChange={(e) => setAsk(e.target.value)}
              disabled={sending}
            />
            {ask.trim() && (
              <button
                type="submit"
                className="icon-button"
                aria-label="Send calendar question"
                disabled={blocked || sending}
              >
                {sending ? <Spinner /> : <ArrowUp size={14} />}
              </button>
            )}
          </form>
        )}
        <div
          className="calendar-segment"
          role="group"
          aria-label="Calendar view"
        >
          {(["day", "week", "month"] as const).map((value) => (
            <button
              key={value}
              aria-pressed={mode === value}
              onClick={() => {
                setMode(value);
                setDetailKey(undefined);
              }}
            >
              {value[0].toUpperCase() + value.slice(1)}
            </button>
          ))}
        </div>
        <button
          className="icon-button calendar-refresh"
          title="Refresh events"
          aria-label="Refresh events"
          disabled={loading}
          onClick={() => setRefresh((n) => n + 1)}
        >
          {loading ? <Spinner /> : <RefreshCw size={14} />}
        </button>
        {!readOnly && (
          <button
            className="button primary calendar-new"
            aria-label="New event"
            title="New event"
            disabled={writeBusy}
            onClick={() => setNewEvent(true)}
          >
            <Plus size={18} />
          </button>
        )}
      </header>
      <div className="calendar-notices">
        <InlineError message={error} />
        {state.directWriteNotice && (
          <div className="notice" role="alert">
            <p>{state.directWriteNotice}</p>
            <button className="text-button" onClick={() => void command({ action: "dismissDirectWriteNotice" }).catch(() => {})}>
              Dismiss
            </button>
          </div>
        )}
        {state.calendarChange && (
          <p className="notice calendar-change-notice" role="status">
            {calendarChangeText(state.calendarChange)}{" "}
            <button className="text-button" onClick={() => void command({ action: "dismissCalendarChange" }).catch(() => {})}>
              Dismiss
            </button>
          </p>
        )}
        {!!errors.length && (
          <div className="calendar-load-errors" role="alert">
            <strong>Some calendars couldn’t be loaded</strong>
            {errors.map((e) => (
              <p key={e.calendarIdentifier}>
                {e.calendarName}: {e.message}
              </p>
            ))}
            <button
              className="text-button"
              onClick={() => setRefresh((n) => n + 1)}
            >
              Try again
            </button>
          </div>
        )}
        {matches && view?.truncated && (
          <p className="notice" role="status">
            Some events may be missing in this busy range. Check the calendar
            provider for the full list.
          </p>
        )}
        {blocked && (
          <p className="calendar-task-notice">
            A task is waiting in Assistant.{" "}
            <button
              className="text-button"
              onClick={() =>
                void command({ action: "navigate", page: "chat" }).catch((e) =>
                  setError(e.message),
                )
              }
            >
              Continue task
            </button>
          </p>
        )}
      </div>
      {!visibleSources.length ? (
        <Empty
          icon={<CalendarDays size={28} />}
          title={state.sharing?.error ? "Friend calendars couldn’t be verified" : "Connect a calendar to see your schedule"}
          action={
            <button className="button primary" onClick={openSettings}>
              Connect calendars
            </button>
          }
        >
          Add an account in Settings or allow access to your macOS calendars.
        </Empty>
      ) : (
        <>
          <div className="calendar-board" ref={board} aria-busy={loading}>
            {mode === "month" ? (
              <section className="month-board" aria-label="Month calendar">
                <div className="weekday-labels">
                  {["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map(
                    (day) => (
                      <span key={day}>{day}</span>
                    ),
                  )}
                </div>
                <div
                  className="month-grid"
                  style={{
                    gridTemplateRows: `repeat(${range.days.length / 7}, minmax(86px, 1fr))`,
                  }}
                >
                  {range.days.map((day) => {
                    const items = events.filter((e) => occursOn(e, day));
                    return (
                      <div
                        key={dayKey(day)}
                        className={
                          "month-day " +
                          (day.getMonth() !== anchor.getMonth()
                            ? "outside "
                            : "") +
                          (dayKey(day) === dayKey(now) ? "today" : "")
                        }
                      >
                        <button
                          className="day-number"
                          aria-label={`Open ${labelDay(day)}`}
                          onClick={() => {
                            setAnchor(day);
                            setMode("day");
                          }}
                        >
                          {day.getDate()}
                        </button>
                        {items.slice(0, 3).map((event) => (
                          <button
                            key={eventKey(event)}
                            className={
                              "month-event " + (isAllDayEvent(event) ? "all-day" : "")
                            }
                            style={tint(event)}
                            aria-label={eventLabel(event)}
                            onClick={() => { setAskSelection(undefined); setAsk(""); setDetailKey(eventKey(event)); }}
                          >
                            <span className="calendar-event-dot" />
                            <span className="truncate">
                              {event.title || "Untitled event"}
                            </span>
                            {!isAllDayEvent(event) && (
                              <time>
                                {new Date(event.start).toLocaleTimeString(
                                  undefined,
                                  { hour: "numeric", minute: "2-digit" },
                                )}
                              </time>
                            )}
                          </button>
                        ))}
                        {items.length > 3 && (
                          <button
                            className="month-more"
                            onClick={() => {
                              setAnchor(day);
                              setMode("day");
                            }}
                          >
                            +{items.length - 3} more
                          </button>
                        )}
                      </div>
                    );
                  })}
                </div>
              </section>
            ) : (
              <section
                className="timetable"
                aria-label={mode === "week" ? "Week calendar" : "Day calendar"}
              >
                <div className="timetable-header" style={columns}>
                  <div />
                  {days.map((day) => (
                    <button
                      key={dayKey(day)}
                      className={
                        "timetable-day " +
                        (dayKey(day) === dayKey(now) ? "today" : "")
                      }
                      onClick={() => {
                        setAnchor(day);
                        setMode("day");
                      }}
                      aria-label={`Open ${labelDay(day)}`}
                    >
                      <span>
                        {day.toLocaleDateString(undefined, {
                          weekday: "short",
                        })}
                      </span>
                      <strong>{day.getDate()}</strong>
                    </button>
                  ))}
                </div>
                <div
                  className="timetable-all-day"
                  style={{
                    ...columns,
                    maxHeight: 112,
                    minHeight: 28,
                    height: 6 + allDayRows * 23,
                  }}
                >
                  <span className="all-day-label">all-day</span>
                  {days.map((day, index) => {
                    const items = allDayByDay[index];
                    return (
                      <div className="all-day-cell" key={dayKey(day)}>
                        {items.slice(0, allDayLimit).map((event) => (
                          <button
                            key={eventKey(event)}
                            className="all-day-event"
                            style={tint(event)}
                            aria-label={eventLabel(event)}
                            title={event.title || "Untitled event"}
                            onClick={() => { setAskSelection(undefined); setAsk(""); setDetailKey(eventKey(event)); }}
                          >
                            {event.title || "Untitled event"}
                          </button>
                        ))}
                        {items.length > allDayLimit && (
                          <button
                            className="month-more"
                            aria-label={`Show ${items.length - allDayLimit} more all-day events on ${labelDay(day)}`}
                            onClick={() => {
                              setAnchor(day);
                              setMode("day");
                            }}
                          >
                            +{items.length - allDayLimit} more
                          </button>
                        )}
                      </div>
                    );
                  })}
                </div>
                <div className="timetable-scroll" ref={scroller}>
                  <div
                    className="timetable-grid"
                    style={{ ...columns, height: gridHeight }}
                  >
                    <div className="hour-gutter">
                      {hours.slice(1, -1).map((hour) => (
                        <span
                          key={hour}
                          style={{ top: (hour - firstHour) * hourHeight }}
                        >
                          {new Date(2026, 0, 1, hour).toLocaleTimeString(
                            undefined,
                            { hour: "numeric" },
                          )}
                        </span>
                      ))}
                    </div>
                    {days.map((day) => (
                      <div
                        key={dayKey(day)}
                        className={
                          "timetable-column " +
                          (dayKey(day) === dayKey(now) ? "today" : "")
                        }
                        aria-label={labelDay(day)}
                      >
                        {layoutDayEvents(events, day).map(
                          ({ event, from, to, lane, lanes }) => (
                            <button
                              key={eventKey(event)}
                              className={
                                "time-event " +
                                (detailKey === eventKey(event)
                                  ? "selected "
                                  : "") +
                                (to - from < 45 ? "short" : "")
                              }
                              style={{
                                ...tint(event),
                                top: (from / 60 - firstHour) * hourHeight,
                                height: Math.max(
                                  24,
                                  ((to - from) / 60) * hourHeight - 2,
                                ),
                                left: `calc(${(lane / lanes) * 100}% + 3px)`,
                                width: `calc(${100 / lanes}% - 6px)`,
                              }}
                              aria-label={eventLabel(event)}
                              title={eventLabel(event)}
                              onClick={() => { setAskSelection(undefined); setAsk(""); setDetailKey(eventKey(event)); }}
                            >
                              <strong>{event.title || "Untitled event"}</strong>
                              <span>{timeRange(event.start, event.end)}</span>
                              {mode === "day" && (
                                <small>
                                  {event.calendarName}
                                  {event.location ? " · " + event.location : ""}
                                </small>
                              )}
                            </button>
                          ),
                        )}
                        {dayKey(day) === dayKey(now) &&
                          minuteOfDay(now) >= firstHour * 60 &&
                          minuteOfDay(now) < lastHour * 60 && (
                            <div
                              className="calendar-now"
                              aria-label="Current time"
                              style={{
                                top:
                                  (minuteOfDay(now) / 60 - firstHour) *
                                  hourHeight,
                              }}
                            />
                          )}
                      </div>
                    ))}
                  </div>
                </div>
              </section>
            )}
            {!loading &&
              !events.some((e) =>
                (mode === "month" ? range.days : days).some((day) =>
                  occursOn(e, day),
                ),
              ) && (
                <div className="calendar-empty-label" role="status">
                  {!ids.length
                    ? "Choose calendars in the sidebar to see your events."
                    : errors.length || error
                      ? "Some calendars couldn’t be checked."
                      : matches
                        ? `Nothing scheduled this ${mode}.`
                        : "Waiting for calendar data…"}
                </div>
              )}
          </div>
          <footer className="calendar-status" role="status">
            <span>
              {loading
                ? "Loading events…"
                : error
                  ? "Couldn’t refresh calendars"
                  : errors.length
                    ? "Some calendars unavailable"
                    : !ids.length
                      ? "No calendars selected"
                      : !matches
                        ? "Waiting for calendar data…"
                        : "Calendars up to date"}
            </span>
            <span>
              {Intl.DateTimeFormat()
                .resolvedOptions()
                .timeZone.replaceAll("_", " ")}
            </span>
          </footer>
        </>
      )}
      {detail && detailInfo && (
        <Modal
          title={detail.title || "Event details"}
          onClose={() => setDetailKey(undefined)}
          className="calendar-event-popover"
        >
          <div className="calendar-event-detail">
            <p>
              <CalendarDays size={15} />
              {detailInfo.allDay
                ? detailInfo.last === detailInfo.first
                  ? keyToDate(detailInfo.first).toLocaleDateString(undefined, {
                      dateStyle: "full",
                    })
                  : `${keyToDate(detailInfo.first).toLocaleDateString(undefined, { dateStyle: "medium" })} – ${keyToDate(detailInfo.last).toLocaleDateString(undefined, { dateStyle: "medium" })}`
                : new Date(detail.start).toLocaleDateString(undefined, {
                    dateStyle: "full",
                  })}
            </p>
            <p>
              <Clock size={15} />
              {timeRange(detail.start, detail.end, undefined, detailInfo.allDay)}
              {detailInfo.dueTime && ` · due ${dueLabel(detailInfo.dueTime)}`}
            </p>
            <p>
              <span
                className="calendar-color"
                style={{ background: color(detail.calendarIdentifier) }}
              />
              {detail.calendarName} <small>· {detail.sourceName}</small>
            </p>
            {detail.location && (
              <p>
                <MapPin size={15} />
                {detail.location}
              </p>
            )}
            {detail.notes && <p className="event-notes">{detail.notes}</p>}
            {detail.timeZone && <small>{detail.timeZone}</small>}
            {detail.calendarIdentifier.startsWith("shared:") && <Badge>Shared · Read-only</Badge>}
            {deadlineTask && !readOnly && (
              <>
                <p className="fine-print">
                  This is the deadline for “{deadlineTask.title}” in Tasks. Edit the task to change or remove it.
                </p>
                <button className="button secondary" onClick={() => openTask(deadlineTask.id)}>
                  <Pencil size={14} /> Edit task
                </button>
              </>
            )}
            {canLink && !deadlineTask && (
              <>
                {taskNotice?.status === "success" && taskNotice.receipt ? (
                  <div role="status">
                    <p>{taskNotice.receipt.outcome === "alreadyLinkedArchived" ? "Already linked to an archived task on this Mac. Open Tasks → Archived to restore it." : taskNotice.receipt.outcome === "alreadyLinked" ? "Already linked to Tasks on this Mac." : "Added to Tasks on this Mac."} The source calendar event stays unchanged.</p>
                    <button className="button secondary" onClick={() => void command({ action: "navigate", page: "tasks" }).catch((e) => setLinkErrors((old) => ({ ...old, [detail.selectionHandle!]: e.message })))}>View Tasks</button>
                  </div>
                ) : (
                  <button className="button secondary" disabled={blocked || linking || taskNotice?.status === "loading"} onClick={() => void linkSelected()}>
                    {linking || taskNotice?.status === "loading" ? <Spinner /> : null}
                    {linking || taskNotice?.status === "loading" ? "Adding to Tasks…" : "Add to Tasks"}
                  </button>
                )}
                {(taskNotice?.status === "error" || linkErrors[detail.selectionHandle!]) && <InlineError message={linkErrors[detail.selectionHandle!] || taskNotice?.message || "Couldn’t add this event to Tasks. Try again."} />}
                {blocked && <p className="fine-print">Finish or stop the current task before adding this event to Tasks.</p>}
                <button className="button secondary" disabled={blocked || linking} onClick={() => askAbout("For this selected event, ")}>Ask Calshot about this</button>
              </>
            )}
            {canChange && !deadlineTask && (
              <>
                <button
                  className="button secondary"
                  disabled={writeBusy || !canDirectChange}
                  onClick={() => {
                    setEditingEvent(detail);
                    setDetailKey(undefined);
                  }}
                >
                  <Pencil size={14} /> Edit event
                </button>
                <button
                  className="button secondary danger"
                  disabled={writeBusy || !canDirectChange}
                  onClick={() => {
                    setDeletingEvent(detail);
                    setDetailKey(undefined);
                  }}
                >
                  <Trash2 size={14} /> Delete event
                </button>
                {detail.isRecurring === true && (
                  <p className="fine-print">
                    Edit and delete change only this date. Other dates in the
                    series stay the same.
                  </p>
                )}
                {writeBusy && (
                  <p className="fine-print">
                    Wait for the current save to finish before changing this event.
                  </p>
                )}
              </>
            )}
          </div>
        </Modal>
      )}
      {newEvent && (
        <NewEvent
          state={state}
          date={dayKey(anchor)}
          onClose={() => setNewEvent(false)}
          onSaved={changeSaved}
          onCommand={command}
        />
      )}
      {editingEvent && (
        <DirectEventEditor
          event={editingEvent}
          onClose={() => setEditingEvent(undefined)}
          onSaved={changeSaved}
          onCommand={command}
        />
      )}
      {deletingEvent && (
        <DeleteEventConfirm
          event={deletingEvent}
          onClose={() => setDeletingEvent(undefined)}
          onSaved={changeSaved}
          onCommand={command}
        />
      )}
    </div>
  );
}

function calendarChangeText(change: NonNullable<AppState["calendarChange"]>) {
  const title = `“${change.title || "Untitled event"}”`;
  if (change.operation === "create") return `Added ${title} to ${change.calendarName}.`;
  if (change.operation === "delete")
    return `Deleted ${title} from ${change.calendarName}.${change.thisDateOnly ? " Other dates in the series stay." : ""}`;
  return `Saved changes to ${title} in ${change.calendarName}.${change.thisDateOnly ? " Only this date changed." : ""}`;
}

function NewEvent({
  state,
  date,
  onClose,
  onSaved,
  onCommand,
}: {
  state: AppState;
  date: string;
  onClose: () => void;
  onSaved: () => void;
  onCommand: (message: Command) => Promise<void>;
}) {
  const writable = state.calendars.filter(
    (c) => !c.isReadOnly && !c.unavailable,
  );
  const [title, setTitle] = useState("");
  const [day, setDay] = useState(date);
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [allDay, setAllDay] = useState(false);
  const [calendarID, setCalendarID] = useState(
    writable.find((c) => c.id === state.selectedCalendarID)?.id ||
      writable[0]?.id ||
      "",
  );
  const [error, setError] = useState("");
  const [invalid, setInvalid] = useState("");
  const [sending, setSending] = useState(false);
  const submit = async (allowDuplicate = false) => {
    setError("");
    setInvalid("");
    if (!title.trim()) {
      setInvalid("title");
      setError("Give your event a title.");
      return;
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) {
      setInvalid("date");
      setError("Choose the event date.");
      return;
    }
    if (!allDay && (!start || !end || end <= start)) {
      setInvalid("time");
      setError("Choose a start time and a later end time, or select All day.");
      return;
    }
    const calendar = writable.find((c) => c.id === calendarID);
    if (!calendar) {
      setInvalid("calendar");
      setError("Choose an available calendar.");
      return;
    }
    setSending(true);
    try {
      await onCommand({
        action: "changeCalendarEvent",
        operation: "create",
        fields: {
          title: title.trim(),
          date: day,
          allDay,
          startTime: start,
          endTime: end,
          timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
          calendarID,
        },
        ...(allowDuplicate ? { allowDuplicate: true } : {}),
      });
      onSaved();
      onClose();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSending(false);
    }
  };
  const destination = writable.find((c) => c.id === calendarID);
  const duplicate = error.startsWith(duplicatePrefix);
  return (
    <Modal title="New event" onClose={onClose}>
      <form
        className="calendar-new-form"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        <label>
          Title
          <input
            autoFocus
            value={title}
            aria-invalid={invalid === "title"}
            maxLength={500}
            onChange={(e) => setTitle(e.target.value)}
          />
        </label>
        {invalid === "title" && <InlineError message={error} />}
        <label>
          Date
          <input
            type="date"
            value={day}
            aria-invalid={invalid === "date"}
            onChange={(e) => setDay(e.target.value)}
          />
        </label>
        {invalid === "date" && <InlineError message={error} />}
        <label className="calendar-all-day-check">
          <input
            type="checkbox"
            checked={allDay}
            onChange={(e) => setAllDay(e.target.checked)}
          />
          All day
        </label>
        {!allDay && (
          <div className="calendar-time-fields">
            <label>
              Starts
              <input
                type="time"
                value={start}
                onChange={(e) => setStart(e.target.value)}
              />
            </label>
            <label>
              Ends
              <input
                type="time"
                value={end}
                onChange={(e) => setEnd(e.target.value)}
              />
            </label>
          </div>
        )}
        {invalid === "time" && <InlineError message={error} />}
        <label>
          Calendar
          <select
            value={calendarID}
            onChange={(e) => setCalendarID(e.target.value)}
          >
            {!writable.length && (
              <option value="">Connect a writable calendar</option>
            )}
            {writable.map((c) => (
              <option value={c.id} key={c.id}>
                {c.title} · {c.sourceName}
              </option>
            ))}
          </select>
        </label>
        {(!invalid || invalid === "calendar") && (
          <InlineError message={error}>
            {duplicate && (
              <button type="button" className="text-button" disabled={sending} onClick={() => void submit(true)}>
                Add anyway
              </button>
            )}
          </InlineError>
        )}
        {destination && (
          <p className="fine-print">Adds this event to {destination.title}.</p>
        )}
        <footer>
          <button type="button" className="button secondary" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button primary"
            type="submit"
            disabled={sending || !writable.length}
          >
            {sending ? <Spinner /> : <Plus size={14} />} {sending ? "Adding…" : "Add event"}
          </button>
        </footer>
      </form>
    </Modal>
  );
}

function eventFormDefaults(event: CalendarEvent) {
  const info = eventInfo(event);
  return {
    title: event.title || "",
    date: info.allDay
      ? info.first
      : zoneDayKey(Date.parse(event.start), event.timeZone),
    startTime: info.allDay ? "" : localTime(event.start, event.timeZone),
    endTime: info.allDay ? "" : localTime(event.end, event.timeZone),
    allDay: info.allDay,
    timeZone:
      event.timeZone || Intl.DateTimeFormat().resolvedOptions().timeZone,
    location: event.location || "",
    url: event.url || "",
    notes: event.notes || "",
  };
}

function DirectEventEditor({
  event,
  onClose,
  onSaved,
  onCommand,
}: {
  event: CalendarEvent;
  onClose: () => void;
  onSaved: () => void;
  onCommand: (message: Command) => Promise<void>;
}) {
  const [form, setForm] = useState(() => eventFormDefaults(event));
  const [error, setError] = useState("");
  const [invalid, setInvalid] = useState("");
  const [saving, setSaving] = useState(false);
  const change = (key: keyof typeof form, value: string | boolean) =>
    setForm((old) => ({ ...old, [key]: value }));
  const submit = async () => {
    setError("");
    setInvalid("");
    if (!form.title.trim()) {
      setInvalid("title");
      setError("Give your event a title.");
      return;
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(form.date)) {
      setInvalid("date");
      setError("Choose the event date.");
      return;
    }
    if (!form.allDay && (!form.startTime || !form.endTime || form.endTime <= form.startTime)) {
      setInvalid("time");
      setError("Choose a start time and a later end time, or select All day.");
      return;
    }
    setSaving(true);
    try {
      await onCommand({
        action: "changeCalendarEvent",
        operation: "update",
        selectionHandle: event.selectionHandle,
        selectionGeneration: event.selectionGeneration,
        fields: {
          title: form.title.trim(),
          date: form.date,
          allDay: form.allDay,
          startTime: form.startTime,
          endTime: form.endTime,
          timeZone: form.timeZone,
          location: form.location,
          url: form.url,
          notes: form.notes,
        },
      });
      onSaved();
      onClose();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };
  return (
    <Modal title="Edit event" onClose={onClose}>
      <form
        className="calendar-new-form"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        <label>
          Title
          <input
            autoFocus
            value={form.title}
            aria-invalid={invalid === "title"}
            maxLength={500}
            onChange={(e) => change("title", e.target.value)}
          />
        </label>
        {invalid === "title" && <InlineError message={error} />}
        <label>
          Date
          <input
            type="date"
            value={form.date}
            aria-invalid={invalid === "date"}
            onChange={(e) => change("date", e.target.value)}
          />
        </label>
        {invalid === "date" && <InlineError message={error} />}
        <label className="calendar-all-day-check">
          <input
            type="checkbox"
            checked={form.allDay}
            onChange={(e) => change("allDay", e.target.checked)}
          />
          All day
        </label>
        {!form.allDay && (
          <div className="calendar-time-fields">
            <label>
              Starts
              <input
                type="time"
                value={form.startTime}
                onChange={(e) => change("startTime", e.target.value)}
              />
            </label>
            <label>
              Ends
              <input
                type="time"
                value={form.endTime}
                onChange={(e) => change("endTime", e.target.value)}
              />
            </label>
          </div>
        )}
        {invalid === "time" && <InlineError message={error} />}
        <label>
          Time zone
          <input
            value={form.timeZone}
            onChange={(e) => change("timeZone", e.target.value)}
          />
        </label>
        <div className="calendar-time-fields">
          <label>
            Location
            <input
              value={form.location}
              onChange={(e) => change("location", e.target.value)}
            />
          </label>
          <label>
            Link
            <input
              type="url"
              value={form.url}
              onChange={(e) => change("url", e.target.value)}
            />
          </label>
        </div>
        <label>
          Notes
          <textarea
            value={form.notes}
            rows={3}
            onChange={(e) => change("notes", e.target.value)}
          />
        </label>
        {(!invalid || !["title", "date", "time"].includes(invalid)) && (
          <InlineError message={error} />
        )}
        <p className="fine-print">
          Saves to {event.calendarName}.
          {event.isRecurring === true ? " Only this date changes; other dates in the series stay." : ""}
        </p>
        <footer>
          <button type="button" className="button secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="button primary" disabled={saving}>
            {saving ? <Spinner /> : <Pencil size={14} />} {saving ? "Saving…" : "Save changes"}
          </button>
        </footer>
      </form>
    </Modal>
  );
}

function DeleteEventConfirm({
  event,
  onClose,
  onSaved,
  onCommand,
}: {
  event: CalendarEvent;
  onClose: () => void;
  onSaved: () => void;
  onCommand: (message: Command) => Promise<void>;
}) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const info = eventInfo(event);
  const submit = async () => {
    setSaving(true);
    setError("");
    try {
      await onCommand({
        action: "changeCalendarEvent",
        operation: "delete",
        selectionHandle: event.selectionHandle,
        selectionGeneration: event.selectionGeneration,
      });
      onSaved();
      onClose();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };
  return (
    <Modal title="Delete event?" onClose={onClose}>
      <div className="calendar-new-form">
        <div className="delete-preview">
          <strong>{event.title || "Untitled event"}</strong>
          <span>
            {timeRange(event.start, event.end, undefined, info.allDay)}
          </span>
          <span>{event.calendarName}</span>
        </div>
        <p className="fine-print">
          Removes this event from {event.calendarName}.
          {event.isRecurring === true ? " Only this date is removed; other dates in the series stay." : ""}
        </p>
        <InlineError message={error} />
        <footer>
          <button type="button" className="button secondary" onClick={onClose}>
            Cancel
          </button>
          <button
            type="button"
            className="button primary danger-fill"
            disabled={saving}
            onClick={() => void submit()}
          >
            {saving ? <Spinner /> : <Trash2 size={14} />} {saving ? "Deleting…" : "Delete event"}
          </button>
        </footer>
      </div>
    </Modal>
  );
}
