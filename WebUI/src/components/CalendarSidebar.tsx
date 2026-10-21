import { ChevronLeft, ChevronRight, Plus, Settings } from "lucide-react";
import {
  calendarColor,
  dateKey,
  monthDays,
  useCalendar,
} from "../calendarPresentation";
import { friendCalendars, type AppState } from "../types";

export function CalendarSidebar({
  state,
  onAction,
}: {
  state: AppState;
  onAction: (action: string, extra?: Record<string, unknown>) => Promise<void>;
}) {
  const { anchor, setAnchor, hidden, toggleCalendar } = useCalendar();
  const days = monthDays(anchor);
  const week = new Date(anchor);
  week.setDate(week.getDate() - week.getDay());
  const weekEnd = new Date(week);
  weekEnd.setDate(weekEnd.getDate() + 7);
  const changeMonth = (offset: number) =>
    setAnchor(new Date(anchor.getFullYear(), anchor.getMonth() + offset, 1));
  const openSettings = () =>
    void onAction("navigate", { page: "settings", section: "calendars" });
  return (
    <div className="calendar-sidebar-content">
      <section className="mini-calendar" aria-label="Choose a date">
        <div className="mini-calendar-heading">
          <strong>
            {anchor.toLocaleDateString(undefined, {
              month: "long",
              year: "numeric",
            })}
          </strong>
          <button
            className="icon-button"
            aria-label="Previous mini calendar month"
            onClick={() => changeMonth(-1)}
          >
            <ChevronLeft size={13} />
          </button>
          <button
            className="icon-button"
            aria-label="Next mini calendar month"
            onClick={() => changeMonth(1)}
          >
            <ChevronRight size={13} />
          </button>
        </div>
        <div className="mini-calendar-grid">
          {["S", "M", "T", "W", "T", "F", "S"].map((d, i) => (
            <span key={i}>{d}</span>
          ))}
          {days.map((day) => (
            <button
              key={dateKey(day)}
              className={
                (day.getMonth() !== anchor.getMonth() ? "outside " : "") +
                (day >= week && day < weekEnd ? "in-week " : "") +
                (dateKey(day) === dateKey(anchor) ? "chosen " : "") +
                (dateKey(day) === dateKey(new Date()) ? "today" : "")
              }
              aria-label={day.toLocaleDateString(undefined, {
                dateStyle: "full",
              })}
              aria-pressed={dateKey(day) === dateKey(anchor)}
              onClick={() => setAnchor(day)}
            >
              {day.getDate()}
            </button>
          ))}
        </div>
      </section>
      <section aria-label="Visible calendars" className="sidebar-calendar-list">
        <div className="calendar-section-heading">
          <h2>My calendars</h2>
          <button
            className="icon-button"
            aria-label="Manage calendar accounts"
            title="Manage calendar accounts"
            onClick={openSettings}
          >
            <Settings size={13} />
          </button>
        </div>
        {state.calendars.map((calendar, index) => (
          <label
            key={calendar.id}
            title={`${calendar.title} · ${calendar.sourceName}${calendar.isReadOnly ? " · Read only" : ""}`}
          >
            <input
              type="checkbox"
              aria-label={`Show ${calendar.title}`}
              checked={!hidden.has(calendar.id)}
              style={{ accentColor: calendarColor(index) }}
              onChange={() => toggleCalendar(calendar.id)}
            />
            <span className="truncate">{calendar.title}</span>
            <small>
              {calendar.unavailable ? "Offline" : calendar.sourceName}
            </small>
          </label>
        ))}
        {!state.calendars.length && (
          <p className="fine-print">Connect a calendar to see your schedule.</p>
        )}
        <button className="calendar-add-account" onClick={openSettings}>
          <Plus size={14} /> Add a calendar
        </button>
      </section>
      {state.sharing && (
        <section
          className="sidebar-calendar-list friend-calendar-section"
          aria-label="Friend calendars"
        >
          <div className="calendar-section-heading">
            <h2>Friends’ calendars</h2>
            <button
              className="icon-button"
              aria-label="Manage friends and sharing"
              title="Friends & sharing"
              onClick={() =>
                void onAction("navigate", {
                  page: "settings",
                  section: "friends",
                })
              }
            >
              <Settings size={13} />
            </button>
          </div>
          {friendCalendars(state).map((calendar, index) => (
            <label key={calendar.id}>
              <input
                type="checkbox"
                checked={!hidden.has(calendar.id)}
                aria-label={`Show ${calendar.sourceName} · ${calendar.title}`}
                style={{
                  accentColor: calendarColor(state.calendars.length + index),
                }}
                onChange={() => toggleCalendar(calendar.id)}
              />
              <span className="truncate" title={calendar.title}>
                {calendar.title}
              </span>
              <small title={calendar.sourceName}>{calendar.sourceName}</small>
            </label>
          ))}
          {!friendCalendars(state).length && (
            <p className="fine-print">
              {state.sharing?.error
                ? "Sharing is unavailable. Refresh in Settings."
                : "Calendars friends share with you appear here."}
            </p>
          )}
          <button
            className="calendar-add-account"
            onClick={() =>
              void onAction("navigate", {
                page: "settings",
                section: "friends",
              })
            }
          >
            <Plus size={14} /> Friends & sharing
          </button>
        </section>
      )}
    </div>
  );
}
