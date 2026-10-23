import type { CalendarEvent } from "./types";
import { dateKey } from "./calendarPresentation";

// Display classification for calendar events. Providers own the all-day flag.
// The only other all-day source is the deadline metadata Calshot writes into
// linked task deadlines, which lets earlier timed copies display compactly
// without a calendar write. Duration alone never makes an event all-day.

const FORMATTER_LIMIT = 64;
const formatters = new Map<string, Intl.DateTimeFormat | null>();
function formatter(zone?: string): Intl.DateTimeFormat {
  const id = zone || "";
  let value = formatters.get(id);
  if (value === undefined) {
    try {
      value = new Intl.DateTimeFormat("en-CA", {
        timeZone: zone || undefined,
        hourCycle: "h23",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      });
    } catch {
      value = null;
    }
    // Zones come from calendar data, so keep the cache bounded.
    if (formatters.size >= FORMATTER_LIMIT) formatters.clear();
    formatters.set(id, value);
  }
  return value ?? formatter();
}
function zoneParts(ms: number, zone?: string) {
  const parts = formatter(zone).formatToParts(new Date(ms));
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "00";
  return {
    date: `${get("year")}-${get("month")}-${get("day")}`,
    time: `${get("hour")}:${get("minute")}:${get("second")}`,
  };
}
/** Calendar date (YYYY-MM-DD) of an instant in `zone`, or the viewer's zone. */
export const zoneDayKey = (ms: number, zone?: string) => zoneParts(ms, zone).date;
/** Wall-clock stamp of an instant in `zone`, e.g. "2026-10-23 00:00". */
const zoneStamp = (ms: number, zone?: string) => {
  const { date, time } = zoneParts(ms, zone);
  return `${date} ${time.slice(0, 5)}`;
};

export interface DeadlineMarker {
  taskID: string;
  date: string;
  time?: string;
  zone: string;
}
const MARKER =
  /Calshot task: ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\n\s*Deadline: (\d{4}-\d{2}-\d{2})(?: at ((?:[01]\d|2[0-3]):[0-5]\d)| \(date only\))\s*·\s*(\S+)\s*\n\s*This deadline does not reserve work time\./i;
function plainText(notes: string) {
  return notes
    .replace(/\r\n?/g, "\n")
    .replace(/<br\s*\/?>|<\/(?:p|div|li)>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/gi, " ")
    .replace(/&middot;|&#183;|&#xb7;/gi, "·")
    .replace(/&amp;/gi, "&");
}
/** Reads the metadata block Calshot appends to every linked task deadline. */
export function deadlineMarker(notes?: string): DeadlineMarker | undefined {
  if (!notes || !notes.includes("Calshot task:")) return undefined;
  const match = MARKER.exec(plainText(notes));
  if (!match) return undefined;
  const [, taskID, date, time, zone] = match;
  const [y, m, d] = date.split("-").map(Number);
  const real = new Date(Date.UTC(y, m - 1, d));
  if (
    real.getUTCFullYear() !== y ||
    real.getUTCMonth() !== m - 1 ||
    real.getUTCDate() !== d
  )
    return undefined;
  try {
    new Intl.DateTimeFormat("en-CA", { timeZone: zone });
  } catch {
    return undefined;
  }
  return { taskID: taskID.toLowerCase(), date, time, zone };
}

const startsAtMidnight = (ms: number, zone: string) =>
  ms % 1000 === 0 && zoneParts(ms, zone).time === "00:00:00";

export interface EventInfo {
  allDay: boolean;
  /** First and last included calendar dates for all-day events. */
  first: string;
  last: string;
  startMs: number;
  endMs: number;
  deadline?: DeadlineMarker;
  /** Due time to show, only when the marker date is one of the rendered days. */
  dueTime?: string;
}
const cache = new WeakMap<CalendarEvent, EventInfo>();
export function eventInfo(event: CalendarEvent): EventInfo {
  const known = cache.get(event);
  if (known) return known;
  const startMs = Date.parse(event.start),
    endMs = Date.parse(event.end);
  const valid = Number.isFinite(startMs) && Number.isFinite(endMs);
  const deadline = deadlineMarker(event.notes);
  let allDay = false,
    first = "",
    last = "";
  if (event.isAllDay) {
    allDay = true;
    if (valid) {
      first = zoneDayKey(startMs, event.timeZone);
      // The end is exclusive. EventKit reports the final included day as
      // 23:59:59, so the last day is whichever day contains the end minus 1 ms.
      last = endMs > startMs ? zoneDayKey(endMs - 1, event.timeZone) : first;
      if (last < first) last = first;
    } else first = last = event.start.slice(0, 10);
  } else if (
    deadline &&
    valid &&
    endMs > startMs &&
    startsAtMidnight(startMs, deadline.zone) &&
    zoneDayKey(startMs, deadline.zone) === deadline.date &&
    zoneDayKey(endMs - 1, deadline.zone) === deadline.date
  ) {
    // A timed copy that starts at midnight and ends inside its own deadline
    // day. Appointments inside that day stay timed.
    allDay = true;
    first = last = deadline.date;
  }
  const dueTime =
    allDay && deadline?.time && first <= deadline.date && deadline.date <= last
      ? deadline.time
      : undefined;
  const info = { allDay, first, last, startMs, endMs, deadline, dueTime };
  cache.set(event, info);
  return info;
}
export const isAllDayEvent = (event: CalendarEvent) => eventInfo(event).allDay;

/** `day` is local midnight of the displayed day. */
export function occursOn(event: CalendarEvent, day: Date) {
  const info = eventInfo(event);
  if (info.allDay) {
    const key = dateKey(day);
    return info.first <= key && key <= info.last;
  }
  const next = new Date(day);
  next.setDate(next.getDate() + 1);
  return info.startMs < next.getTime() && info.endMs > day.getTime();
}
/** Parses a YYYY-MM-DD key as a local calendar day. */
export const keyToDate = (key: string) => {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y, m - 1, d);
};

/** Dates an event covers in its own zone: the first day and the last included day. */
function coveredDates(event: CalendarEvent) {
  const info = eventInfo(event);
  if (info.allDay && !event.isAllDay) return { first: info.first, last: info.last };
  if (!Number.isFinite(info.startMs) || !Number.isFinite(info.endMs)) return undefined;
  const first = zoneDayKey(info.startMs, event.timeZone);
  const last = info.endMs > info.startMs ? zoneDayKey(info.endMs - 1, event.timeZone) : first;
  return { first, last: last < first ? first : last };
}
const dateWords = (first: string, last: string) =>
  first === last ? `on ${first}` : `from ${first} through ${last}`;
/** The event as the provider stores it, for requests sent to the assistant. */
function providerDescription(event: CalendarEvent) {
  const info = eventInfo(event);
  const zone = event.timeZone ? ` ${event.timeZone}` : "";
  if (!Number.isFinite(info.startMs) || !Number.isFinite(info.endMs))
    return event.isAllDay ? "an all-day event" : "a timed event";
  const range = `${zoneStamp(info.startMs, event.timeZone)} to ${zoneStamp(info.endMs, event.timeZone)}${zone}`;
  if (event.isAllDay) return `an all-day event (provider range ${range})`;
  const shown = info.allDay ? `; Calshot shows it all day ${dateWords(info.first, info.last)} because of its deadline note` : "";
  return `a timed event (provider range ${range}${shown})`;
}
/** Prefix for a free-form change request that states the real stored event. */
export function changeRequestPrefix(event: CalendarEvent) {
  return `Change “${event.title}” in “${event.calendarName}”, currently ${providerDescription(event)}: `;
}
/**
 * Explicit request to turn a timed event into an all-day event. It is only a
 * prefilled message: the user sends it and approves the reviewed change.
 */
export function allDayConversionRequest(event: CalendarEvent) {
  if (event.isAllDay) return undefined;
  const dates = coveredDates(event);
  if (!dates) return undefined;
  return `Make “${event.title}” in “${event.calendarName}” an all-day event ${dateWords(dates.first, dates.last)}. It is currently ${providerDescription(event)}. Keep its title, notes, location and calendar, and show me the change for review before saving.`;
}
