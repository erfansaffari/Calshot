import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { CalendarPage, layoutDayEvents } from "../src/views/CalendarPage";
import {
  allDayConversionRequest,
  changeRequestPrefix,
  deadlineMarker,
  eventInfo,
  isAllDayEvent,
  occursOn,
} from "../src/calendarEvents";
import { CalendarPresentationProvider } from "../src/calendarPresentation";
import { preview } from "../src/preview";
import type { CalendarEvent } from "../src/types";
vi.mock("../src/bridge", () => ({
  command: vi.fn().mockResolvedValue(undefined),
}));
import { command } from "../src/bridge";
afterEach(() => {
  cleanup();
  vi.mocked(command).mockClear();
});

const zone = "America/Toronto";
const base: CalendarEvent = {
  eventIdentifier: "event",
  calendarIdentifier: "school",
  title: "Fictional event",
  start: "2026-10-23T04:00:00Z",
  end: "2026-10-24T04:00:00Z",
  isAllDay: false,
  timeZone: zone,
  calendarName: "School",
  sourceName: "Fictional",
};
const task = "6f1d3c0e-4b7a-4f43-9d0b-0a7c3c1f2e10";
const marker = (date = "2026-10-23", time?: string, tz = zone) =>
  `Read chapter 4.\nCalshot task: ${task}\nDeadline: ${date}${time ? ` at ${time}` : " (date only)"} · ${tz}\nThis deadline does not reserve work time.`;
const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
const day = (d: number) => new Date(2026, 9, d);
const visibleOn = (event: CalendarEvent, from = 21, to = 26) =>
  Array.from({ length: to - from + 1 }, (_, i) => from + i).filter((d) =>
    occursOn(event, day(d)),
  );

it("keeps provider all-day events on their own dates in every provider convention", () => {
  // Google/Outlook/iCloud: exclusive end at the next midnight in the event zone.
  const exclusive = { ...base, isAllDay: true };
  expect(visibleOn(exclusive)).toEqual([23]);
  expect(isAllDayEvent(exclusive)).toBe(true);
  // EventKit reports the final included day as 23:59:59 in the same zone.
  const eventKit = { ...exclusive, end: "2026-10-24T03:59:59Z" };
  expect(visibleOn(eventKit)).toEqual([23]);
  expect(visibleOn({ ...eventKit, end: "2026-10-25T03:59:59Z" })).toEqual([23, 24]);
  expect(visibleOn({ ...exclusive, end: "2026-10-26T04:00:00Z" })).toEqual([23, 24, 25]);
  // A zero-length provider value still shows on its start day.
  expect(visibleOn({ ...exclusive, end: exclusive.start })).toEqual([23]);
});

it("displays a marked timed legacy deadline as an all-day entry on its deadline date only", () => {
  const legacy = {
    ...base,
    title: "Essay · due 17:00",
    start: "2026-10-23T04:00:00Z",
    end: "2026-10-24T03:59:00Z",
    notes: marker("2026-10-23", "17:00"),
  };
  expect(isAllDayEvent(legacy)).toBe(true);
  expect(visibleOn(legacy)).toEqual([23]);
  expect(eventInfo(legacy).deadline).toMatchObject({ date: "2026-10-23", time: "17:00", zone });
  expect(layoutDayEvents([legacy], day(23))).toEqual([]);
  // Midnight-to-midnight and date-only metadata normalise the same way.
  const dateOnly = { ...legacy, end: "2026-10-24T04:00:00Z", notes: marker() };
  expect(isAllDayEvent(dateOnly)).toBe(true);
  expect(eventInfo(dateOnly).deadline?.time).toBeUndefined();
});

it("reads deadline metadata only when it is complete and real", () => {
  expect(deadlineMarker(marker("2026-10-23", "17:00"))).toMatchObject({ taskID: task, time: "17:00" });
  // Outlook can return HTML-wrapped notes.
  const html = marker("2026-10-23", "17:00").replaceAll("\n", "<br>").replace("·", "&middot;");
  expect(deadlineMarker(`<html><body><p>${html}</p></body></html>`)?.date).toBe("2026-10-23");
  expect(deadlineMarker(undefined)).toBeUndefined();
  expect(deadlineMarker("Calshot task: not-a-task\nDeadline: 2026-10-23 (date only) · America/Toronto")).toBeUndefined();
  expect(deadlineMarker(marker("2026-02-30"))).toBeUndefined();
  expect(deadlineMarker(marker("2026-10-23", "25:00"))).toBeUndefined();
  expect(deadlineMarker(marker("2026-10-23", undefined, "Not/AZone"))).toBeUndefined();
  expect(deadlineMarker(marker("2026-10-23").replace("This deadline does not reserve work time.", ""))).toBeUndefined();
});

it("never makes an event all-day from its duration or an unrelated marker", () => {
  const fullDay = { ...base, start: "2026-10-23T04:00:00Z", end: "2026-10-24T03:59:00Z" };
  expect(isAllDayEvent(fullDay)).toBe(false); // unmarked 12:00 AM–11:59 PM stays timed
  expect(layoutDayEvents([fullDay], day(23))).toHaveLength(1);
  const overnight = { ...base, start: new Date(2026, 9, 23, 22).toISOString(), end: new Date(2026, 9, 24, 6).toISOString() };
  expect(isAllDayEvent(overnight)).toBe(false);
  expect(visibleOn(overnight)).toEqual([23, 24]);
  const shift = { ...base, start: new Date(2026, 9, 23, 12).toISOString(), end: new Date(2026, 9, 24, 12).toISOString() }; // 24 h
  expect(isAllDayEvent(shift)).toBe(false);
  expect(visibleOn(shift)).toEqual([23, 24]);
  // A marked event that was moved, extended or crosses midnight keeps its real time.
  const notes = marker("2026-10-23");
  expect(isAllDayEvent({ ...fullDay, notes: marker("2026-10-24") })).toBe(false);
  expect(isAllDayEvent({ ...fullDay, end: "2026-10-25T03:59:00Z", notes })).toBe(false);
  expect(isAllDayEvent({ ...overnight, notes: marker("2026-10-23", undefined, localZone) })).toBe(false);
  expect(isAllDayEvent({ ...fullDay, start: "2026-10-23T03:00:00Z", notes })).toBe(false);
  expect(visibleOn({ ...overnight, notes: marker("2026-10-23", undefined, localZone) })).toEqual([23, 24]);
  // The metadata zone decides the date, not the viewer's.
  expect(isAllDayEvent({ ...fullDay, notes: marker("2026-10-23", undefined, "Asia/Tokyo") })).toBe(false);
});

it("keeps real appointments on a deadline day timed and only trusts midnight-start copies", () => {
  const notes = marker("2026-10-23", "17:00");
  const appointment = { ...base, start: "2026-10-23T18:00:00Z", end: "2026-10-23T19:00:00Z", notes }; // 14:00–15:00 Toronto
  expect(isAllDayEvent(appointment)).toBe(false);
  expect(eventInfo(appointment).dueTime).toBeUndefined();
  expect(layoutDayEvents([appointment], day(23))).toHaveLength(1);
  // Starting one second after midnight is not the legacy shape.
  expect(isAllDayEvent({ ...base, start: "2026-10-23T04:00:01Z", end: "2026-10-24T03:59:00Z", notes })).toBe(false);
  expect(isAllDayEvent({ ...base, start: "2026-10-23T04:00:00Z", end: "2026-10-24T03:59:00Z", notes })).toBe(true);
});

it("uses the marker zone across daylight-saving changes and other zones", () => {
  // Toronto falls back on 2026-11-01: that day is 25 hours long, midnight is still 04:00Z.
  const fall = { ...base, start: "2026-11-01T04:00:00Z", end: "2026-11-02T04:59:00Z", notes: marker("2026-11-01") };
  expect(isAllDayEvent(fall)).toBe(true);
  // The spring-forward day starts at 05:00Z and the next midnight is 04:00Z.
  const spring = { ...base, start: "2026-03-08T05:00:00Z", end: "2026-03-09T03:59:00Z", notes: marker("2026-03-08") };
  expect(isAllDayEvent(spring)).toBe(true);
  // The fall-back day ends exactly at 05:00Z; a copy running past it spills into the next day.
  expect(isAllDayEvent({ ...fall, end: "2026-11-02T05:00:00Z" })).toBe(true);
  expect(isAllDayEvent({ ...fall, end: "2026-11-02T05:00:01Z" })).toBe(false);
  // Tokyo midnight is 15:00Z the day before; the same instants are not midnight in Toronto.
  const tokyo = { ...base, timeZone: "Asia/Tokyo", start: "2026-10-22T15:00:00Z", end: "2026-10-23T14:59:00Z", notes: marker("2026-10-23", undefined, "Asia/Tokyo") };
  expect(isAllDayEvent(tokyo)).toBe(true);
  expect(eventInfo(tokyo).first).toBe("2026-10-23");
  expect(isAllDayEvent({ ...tokyo, notes: marker("2026-10-23", undefined, zone) })).toBe(false);
});

it("shows a due time only when the marker date is among the rendered days", () => {
  const notes = marker("2026-10-23", "17:00");
  const provider = { ...base, isAllDay: true, start: "2026-10-24T04:00:00Z", end: "2026-10-25T04:00:00Z", notes }; // moved to the 24th
  expect(isAllDayEvent(provider)).toBe(true);
  expect(eventInfo(provider).dueTime).toBeUndefined();
  expect(eventInfo({ ...provider, start: "2026-10-23T04:00:00Z" }).dueTime).toBe("17:00");
  const legacy = { ...base, end: "2026-10-24T03:59:00Z", notes };
  expect(eventInfo(legacy).dueTime).toBe("17:00");
  expect(eventInfo({ ...base, start: "2026-10-23T13:00:00Z", end: "2026-10-23T14:00:00Z", notes }).dueTime).toBeUndefined();
});

it("describes the real stored event in assistant requests", () => {
  const legacy = { ...base, title: "Essay", end: "2026-10-24T03:59:00Z", notes: marker("2026-10-23", "17:00") };
  const prefix = changeRequestPrefix(legacy);
  expect(prefix).toContain("a timed event");
  expect(prefix).toContain("2026-10-23 00:00 to 2026-10-23 23:59 America/Toronto");
  expect(prefix).toContain("shows it all day on 2026-10-23");
  const multi = { ...base, isAllDay: true, end: "2026-10-26T04:00:00Z" };
  expect(changeRequestPrefix(multi)).toContain("an all-day event (provider range 2026-10-23 00:00 to 2026-10-26 00:00 America/Toronto)");
  expect(allDayConversionRequest(multi)).toBeUndefined();
  const request = allDayConversionRequest(legacy)!;
  expect(request).toContain("an all-day event on 2026-10-23");
  expect(request).toContain("currently a timed event");
  expect(request).toContain("for review before saving");
  const overnight = { ...base, start: "2026-10-24T02:00:00Z", end: "2026-10-24T10:00:00Z" }; // 22:00 → 06:00
  expect(allDayConversionRequest(overnight)).toContain("from 2026-10-23 through 2026-10-24");
});

it("classifies a month of events quickly and keeps provider flags authoritative", () => {
  const events = Array.from({ length: 3000 }, (_, i) => ({
    ...base,
    eventIdentifier: `e${i}`,
    isAllDay: i % 3 === 0,
    start: new Date(Date.UTC(2026, 9, 1 + (i % 28), 4)).toISOString(),
    end: new Date(Date.UTC(2026, 9, 1 + (i % 28), 4 + (i % 3 === 0 ? 24 : 2))).toISOString(),
    notes: i % 7 === 0 ? marker(`2026-10-${String(1 + (i % 28)).padStart(2, "0")}`) : undefined,
  }));
  const started = performance.now();
  const days = Array.from({ length: 42 }, (_, i) => new Date(2026, 8, 27 + i));
  let shown = 0;
  for (const d of days) for (const event of events) if (occursOn(event, d)) shown++;
  expect(performance.now() - started).toBeLessThan(2000);
  expect(shown).toBeGreaterThanOrEqual(3000);
  expect(events.filter((e) => e.isAllDay).every(isAllDayEvent)).toBe(true);
});

const local = (offset: number) => {
  const date = new Date();
  date.setHours(0, 0, 0, 0);
  // Stay inside the displayed Sunday-based week.
  date.setDate(date.getDate() - date.getDay() + offset);
  return date;
};
const iso = (date: Date, hours = 0, minutes = 0) => {
  const copy = new Date(date);
  copy.setHours(hours, minutes, 0, 0);
  return copy.toISOString();
};
async function renderWeek(events: CalendarEvent[]) {
  const content = (calendarView?: typeof preview.calendarView) => (
    <CalendarPresentationProvider>
      <CalendarPage
        onCommand={command}
        state={{ ...preview, waitingApproval: false, calendarView }}
      />
    </CalendarPresentationProvider>
  );
  const view = render(content());
  // Native answers each range request; mirror that for the latest request.
  const answer = async () => {
    await waitFor(() =>
      expect(command).toHaveBeenCalledWith(expect.objectContaining({ action: "loadCalendarEvents" })),
    );
    const request = vi.mocked(command).mock.calls.filter(([c]) => c.action === "loadCalendarEvents").at(-1)![0];
    view.rerender(
      content({
        loaded: true,
        loading: false,
        start: String(request.start),
        end: String(request.end),
        events: events.map((e) => ({ ...e, calendarIdentifier: preview.calendars[0].id })),
        errors: [],
      }),
    );
  };
  await answer();
  return { ...view, answer };
}

it("puts all-day and linked deadlines in the all-day row and keeps the timetable for timed events", async () => {
  const d = local(3);
  const next = new Date(d);
  next.setDate(d.getDate() + 1);
  const dateKey = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const timedDeadline: CalendarEvent = {
    ...base,
    eventIdentifier: "deadline",
    title: "Lab report · due 17:00",
    timeZone: localZone,
    start: iso(d),
    end: iso(d, 23, 59),
    notes: marker(dateKey, "17:00", localZone),
  };
  const allDay: CalendarEvent = {
    ...base,
    eventIdentifier: "holiday",
    title: "Fictional holiday",
    isAllDay: true,
    timeZone: localZone,
    start: iso(d),
    end: iso(next),
  };
  const overnight: CalendarEvent = {
    ...base,
    eventIdentifier: "night",
    title: "Overnight shift",
    timeZone: localZone,
    start: iso(d, 22),
    end: iso(next, 6),
  };
  const view = await renderWeek([timedDeadline, allDay, overnight]);
  const row = view.container.querySelector<HTMLElement>(".timetable-all-day")!;
  expect(within(row).getByRole("button", { name: /Lab report · due 17:00, All day/ })).toBeDefined();
  expect(within(row).getByRole("button", { name: /Fictional holiday, All day/ })).toBeDefined();
  expect(within(row).queryByRole("button", { name: /Overnight shift/ })).toBeNull();
  const grid = view.container.querySelector<HTMLElement>(".timetable-grid")!;
  expect(within(grid).queryByRole("button", { name: /Lab report/ })).toBeNull();
  expect(within(grid).queryByRole("button", { name: /Fictional holiday/ })).toBeNull();
  expect(within(grid).getAllByRole("button", { name: /Overnight shift/ })).toHaveLength(2);
  expect(view.container.querySelectorAll(".time-event")).toHaveLength(2);

  await userEvent.click(within(row).getByRole("button", { name: /Lab report/ }));
  const dialog = screen.getByRole("dialog", { name: "Lab report · due 17:00" });
  expect(within(dialog).getByText(/All day · due/)).toBeDefined();
});

it("keeps large all-day batches compact in Week and complete in Day", async () => {
  const d = local(2);
  const next = new Date(d);
  next.setDate(d.getDate() + 1);
  const events = Array.from({ length: 12 }, (_, i): CalendarEvent => ({
    ...base,
    eventIdentifier: `deadline-${i}`,
    title: `Fictional deadline ${i + 1}`,
    isAllDay: true,
    timeZone: localZone,
    start: iso(d),
    end: iso(next),
  }));
  const view = await renderWeek(events);
  const row = view.container.querySelector<HTMLElement>(".timetable-all-day")!;
  expect(within(row).getAllByRole("button", { name: /Fictional deadline/ })).toHaveLength(3);
  expect(parseInt(row.style.height)).toBeLessThanOrEqual(6 + 4 * 23);
  await userEvent.click(within(row).getByRole("button", { name: /Show 9 more all-day events/ }));
  await view.answer();
  const dayRow = view.container.querySelector<HTMLElement>(".timetable-all-day")!;
  expect(within(dayRow).getAllByRole("button", { name: /Fictional deadline/ })).toHaveLength(12);
  expect(view.container.querySelectorAll(".time-event")).toHaveLength(0);
});

const timedLegacy = (d: Date, overrides: Partial<CalendarEvent> = {}): CalendarEvent => ({
  ...base,
  eventIdentifier: "legacy",
  title: "Lab report",
  timeZone: localZone,
  start: iso(d),
  end: iso(d, 23, 59),
  ...overrides,
});

it("offers a review-driven Make all-day request for timed events on writable calendars", async () => {
  const d = local(3);
  const view = await renderWeek([timedLegacy(d)]);
  await userEvent.click(view.getByRole("button", { name: /Lab report/ }));
  const dialog = screen.getByRole("dialog", { name: "Lab report" });
  expect(within(dialog).getByRole("button", { name: "Ask Calshot to change this" })).toBeDefined();
  await userEvent.click(within(dialog).getByRole("button", { name: "Make all-day" }));
  const input = screen.getByLabelText("Ask Calshot about your calendar") as HTMLInputElement;
  expect(input.value).toMatch(/Make “Lab report” in “School” an all-day event on \d{4}-\d{2}-\d{2}/);
  expect(input.value).toContain("currently a timed event");
  expect(input.value).toContain("for review before saving");
  // Prefilled only: nothing is sent or written until the user submits it.
  expect(vi.mocked(command).mock.calls.some(([c]) => c.action === "startCalendarTask")).toBe(false);
  await userEvent.click(screen.getByRole("button", { name: "Send calendar question" }));
  expect(command).toHaveBeenCalledWith(
    expect.objectContaining({ action: "startCalendarTask", text: expect.stringContaining("an all-day event on") }),
  );
});

it("hides Make all-day for provider all-day, read-only and unavailable calendars", async () => {
  const d = local(3);
  const next = new Date(d);
  next.setDate(d.getDate() + 1);
  const open = async (event: CalendarEvent) => {
    const view = await renderWeek([event]);
    await userEvent.click(view.getAllByRole("button", { name: new RegExp(event.title) })[0]);
    const dialog = screen.getByRole("dialog", { name: event.title });
    const result = {
      change: within(dialog).queryByRole("button", { name: "Ask Calshot to change this" }),
      convert: within(dialog).queryByRole("button", { name: "Make all-day" }),
    };
    view.unmount();
    cleanup();
    return result;
  };
  const allDay = await open(timedLegacy(d, { isAllDay: true, end: iso(next) }));
  expect(allDay.change).not.toBeNull();
  expect(allDay.convert).toBeNull();
  const original = preview.calendars[0].isReadOnly;
  preview.calendars[0].isReadOnly = true;
  try {
    const readOnly = await open(timedLegacy(d));
    expect(readOnly.change).toBeNull();
    expect(readOnly.convert).toBeNull();
  } finally {
    preview.calendars[0].isReadOnly = original;
  }
});
