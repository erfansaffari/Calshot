import { afterEach, expect, it, vi } from "vitest";
import {
  cleanup,
  render,
  screen,
  waitFor,
  fireEvent,
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { CalendarPage, occursOn } from "../src/views/CalendarPage";
import { SettingsPage } from "../src/views/Pages";
import { preview } from "../src/preview";
import { CalendarPresentationProvider } from "../src/calendarPresentation";
import { Sidebar } from "../src/components/Sidebar";
import type { CalendarEvent } from "../src/types";
vi.mock("../src/bridge", () => ({
  command: vi.fn().mockResolvedValue(undefined),
}));
import { command } from "../src/bridge";
afterEach(() => {
  cleanup();
  vi.mocked(command).mockClear();
});
const event: CalendarEvent = {
  eventIdentifier: "event",
  calendarIdentifier: "school",
  title: "Studio session",
  start: "2026-10-15T04:00:00Z",
  end: "2026-10-17T04:00:00Z",
  isAllDay: true,
  timeZone: "America/Toronto",
  calendarName: "School",
  sourceName: "Google",
};
it("keeps multi-day all-day events on their dates and excludes the end date", () => {
  expect(occursOn(event, new Date(2026, 9, 15))).toBe(true);
  expect(occursOn(event, new Date(2026, 9, 16))).toBe(true);
  expect(occursOn(event, new Date(2026, 9, 17))).toBe(false);
});
it("includes timed events across midnight without adding the exclusive end day", () => {
  const timed = {
    ...event,
    isAllDay: false,
    start: new Date(2026, 9, 15, 23).toISOString(),
    end: new Date(2026, 9, 16, 1).toISOString(),
  };
  expect(occursOn(timed, new Date(2026, 9, 15))).toBe(true);
  expect(occursOn(timed, new Date(2026, 9, 16))).toBe(true);
  expect(occursOn(timed, new Date(2026, 9, 17))).toBe(false);
});
it("separates connections and AI from general settings", async () => {
  render(<SettingsPage state={preview} />);
  expect(screen.getByRole("combobox", { name: "Appearance" })).toBeDefined();
  expect(screen.queryByRole("combobox", { name: "AI service" })).toBeNull();
  await userEvent.click(
    screen.getByRole("button", { name: "Calendar accounts" }),
  );
  expect(
    screen.getByRole("heading", { name: "Calendar accounts" }),
  ).toBeDefined();
  expect(
    screen.getByRole("combobox", {
      name: "Default destination for new events",
    }),
  ).toBeDefined();
  expect(screen.queryByRole("combobox", { name: "Appearance" })).toBeNull();
  await userEvent.click(screen.getByRole("button", { name: "AI service" }));
  expect(screen.getByRole("combobox", { name: "AI service" })).toBeDefined();
});
it("requests a bounded range and filters calendars without changing the destination", async () => {
  render(
    <CalendarPresentationProvider>
      <Sidebar
        state={{ ...preview, page: "calendars" }}
        onAction={async () => {}}
      />
      <CalendarPage onCommand={command} state={preview} />
    </CalendarPresentationProvider>,
  );
  await waitFor(() =>
    expect(command).toHaveBeenCalledWith(
      expect.objectContaining({
        action: "loadCalendarEvents",
        calendarIDs: preview.calendars.map((c) => c.id).sort(),
      }),
    ),
  );
  const calls = vi.mocked(command).mock.calls;
  const request = calls.find(([c]) => c.action === "loadCalendarEvents")![0];
  expect(
    (Date.parse(String(request.end)) - Date.parse(String(request.start))) /
      86400000,
  ).toBeGreaterThanOrEqual(6.95);
  expect((Date.parse(String(request.end)) - Date.parse(String(request.start))) / 86400000).toBeLessThanOrEqual(7.05);
  await userEvent.click(
    screen.getByRole("checkbox", {
      name: new RegExp(preview.calendars[0].title),
    }),
  );
  await waitFor(() =>
    expect(command).toHaveBeenLastCalledWith(
      expect.objectContaining({
        action: "loadCalendarEvents",
        calendarIDs: preview.calendars
          .slice(1)
          .map((c) => c.id)
          .sort(),
      }),
    ),
  );
  expect(calls.some(([c]) => c.action === "selectCalendar")).toBe(false);
});
it("shows connection setup from the empty calendar without proposing writes", async () => {
  render(
    <CalendarPresentationProvider>
      <CalendarPage onCommand={command} state={{ ...preview, calendars: [] }} />
    </CalendarPresentationProvider>,
  );
  await userEvent.click(
    screen.getByRole("button", { name: "Connect calendars" }),
  );
  expect(command).toHaveBeenCalledWith({
    action: "navigate",
    page: "settings",
    section: "calendars",
  });
});
it("keeps read failures visible rather than calling the calendar empty", async () => {
  vi.mocked(command).mockRejectedValueOnce(
    new Error("The calendar could not be loaded."),
  );
  render(
    <CalendarPresentationProvider>
      <Sidebar
        state={{ ...preview, page: "calendars" }}
        onAction={async () => {}}
      />
      <CalendarPage onCommand={command} state={preview} />
    </CalendarPresentationProvider>,
  );
  expect(await screen.findByRole("alert")).toHaveProperty(
    "textContent",
    "The calendar could not be loaded.",
  );
});

it("defaults to the designed week view and keeps Day, Week and Month navigation", async () => {
  render(
    <CalendarPresentationProvider>
      <CalendarPage onCommand={command} state={preview} />
    </CalendarPresentationProvider>,
  );
  expect(screen.getByRole("region", { name: "Week calendar" })).toBeDefined();
  expect(
    screen
      .getByRole("button", { name: "Week", exact: true })
      .getAttribute("aria-pressed"),
  ).toBe("true");
  await userEvent.click(
    screen.getByRole("button", { name: "Day", exact: true }),
  );
  expect(screen.getByRole("region", { name: "Day calendar" })).toBeDefined();
  expect(screen.getByRole("button", { name: "Next day" })).toBeDefined();
  await userEvent.click(
    screen.getByRole("button", { name: "Month", exact: true }),
  );
  expect(screen.getByRole("region", { name: "Month calendar" })).toBeDefined();
  expect(screen.getByRole("button", { name: "Next month" })).toBeDefined();
});

it("keeps calendar questions and their failure beside the input", async () => {
  render(
    <CalendarPresentationProvider>
      <CalendarPage
        onCommand={command}
        state={{ ...preview, waitingApproval: false }}
      />
    </CalendarPresentationProvider>,
  );
  await waitFor(() =>
    expect(command).toHaveBeenCalledWith(
      expect.objectContaining({ action: "loadCalendarEvents" }),
    ),
  );
  await userEvent.type(
    screen.getByRole("textbox", { name: "Ask Calshot about your calendar" }),
    "What do I have tomorrow?",
  );
  vi.mocked(command).mockRejectedValueOnce(
    new Error("The calendar service is unavailable."),
  );
  await userEvent.click(
    screen.getByRole("button", { name: "Send calendar question" }),
  );
  expect(await screen.findByRole("alert")).toHaveProperty(
    "textContent",
    "The calendar service is unavailable.",
  );
  expect(
    (
      screen.getByRole("textbox", {
        name: "Ask Calshot about your calendar",
      }) as HTMLInputElement
    ).value,
  ).toBe("What do I have tomorrow?");
});

it("new events keep missing time unresolved and ask for approval instead of writing", async () => {
  render(
    <CalendarPresentationProvider>
      <CalendarPage
        onCommand={command}
        state={{ ...preview, waitingApproval: false }}
      />
    </CalendarPresentationProvider>,
  );
  await userEvent.click(screen.getByRole("button", { name: "New event" }));
  await userEvent.type(
    screen.getByRole("textbox", { name: "Title" }),
    "Example appointment",
  );
  await userEvent.click(
    screen.getByRole("button", { name: "Review with Calshot" }),
  );
  expect(await screen.findByRole("alert")).toHaveProperty(
    "textContent",
    "Choose a start time and a later end time, or select All day.",
  );
  await userEvent.click(screen.getByRole("checkbox", { name: "All day" }));
  await userEvent.click(
    screen.getByRole("button", { name: "Review with Calshot" }),
  );
  expect(command).toHaveBeenCalledWith(
    expect.objectContaining({
      action: "startCalendarTask",
      text: expect.stringContaining("all day (confirmed)"),
    }),
  );
  expect(
    vi
      .mocked(command)
      .mock.calls.some(([c]) =>
        ["approve", "selectCalendar"].includes(c.action),
      ),
  ).toBe(false);
});

it("does not start a second command during an existing approval", async () => {
  render(
    <CalendarPresentationProvider>
      <CalendarPage onCommand={command} state={preview} />
    </CalendarPresentationProvider>,
  );
  expect(
    (screen.getByRole("button", { name: "New event" }) as HTMLButtonElement)
      .disabled,
  ).toBe(true);
  await userEvent.type(
    screen.getByRole("textbox", { name: "Ask Calshot about your calendar" }),
    "Add another event",
  );
  expect(
    (
      screen.getByRole("button", {
        name: "Send calendar question",
      }) as HTMLButtonElement
    ).disabled,
  ).toBe(true);
});

it("lays out nested and transitive overlaps without hiding any event", async () => {
  const { layoutDayEvents } = await import("../src/views/CalendarPage");
  const day = new Date(2026, 9, 16);
  const timed = (id: string, from: number, to: number) => ({
    ...event,
    isAllDay: false,
    eventIdentifier: id,
    start: new Date(2026, 9, 16, 0, from).toISOString(),
    end: new Date(2026, 9, 16, 0, to).toISOString(),
  });
  const result = layoutDayEvents(
    [
      timed("long", 600, 780),
      timed("short", 630, 660),
      timed("overlap", 650, 730),
      timed("after", 780, 840),
    ],
    day,
  );
  expect(result.slice(0, 3).map((e) => e.lanes)).toEqual([3, 3, 3]);
  expect(new Set(result.slice(0, 3).map((e) => e.lane)).size).toBe(3);
  expect(result[3].lanes).toBe(1);
});

it("clips an overnight event at each day's boundary", async () => {
  const { dayInterval } = await import("../src/views/CalendarPage");
  const night = {
    ...event,
    isAllDay: false,
    start: new Date(2026, 9, 15, 23).toISOString(),
    end: new Date(2026, 9, 16, 1).toISOString(),
  };
  expect(dayInterval(night, new Date(2026, 9, 15))).toEqual({
    from: 1380,
    to: 1440,
  });
  expect(dayInterval(night, new Date(2026, 9, 16))).toEqual({
    from: 0,
    to: 60,
  });
});

it("matches the reference's five-row October while allowing six-row months", async () => {
  const { monthDays } = await import("../src/calendarPresentation");
  expect(monthDays(new Date(2026, 9, 1))).toHaveLength(35);
  expect(monthDays(new Date(2026, 7, 1))).toHaveLength(42);
});

it("opens event details from Month and restores keyboard focus when dismissed", async () => {
  const base = { ...preview, waitingApproval: false };
  const content = (state: typeof base) => (
    <CalendarPresentationProvider>
      <CalendarPage onCommand={command} state={state} />
    </CalendarPresentationProvider>
  );
  const view = render(content(base));
  await waitFor(() =>
    expect(command).toHaveBeenCalledWith(
      expect.objectContaining({ action: "loadCalendarEvents" }),
    ),
  );
  await userEvent.click(screen.getByRole("button", { name: "Month", exact: true }));
  const request = vi
    .mocked(command)
    .mock.calls.filter(([c]) => c.action === "loadCalendarEvents")
    .at(-1)![0];
  const date = new Date();
  date.setHours(10, 0, 0, 0);
  const sample = {
    ...event,
    title: "Fictional design review",
    isAllDay: false,
    calendarIdentifier: base.calendars[0].id,
    start: date.toISOString(),
    end: new Date(date.getTime() + 3600000).toISOString(),
  };
  view.rerender(
    content({
      ...base,
      calendarView: {
        loaded: true,
        loading: false,
        start: String(request.start),
        end: String(request.end),
        events: [sample],
        errors: [],
      },
    }),
  );

  const chip = screen.getByRole("button", { name: /Fictional design review/ });
  await userEvent.click(chip);
  expect(
    screen.getByRole("dialog", { name: "Fictional design review" }),
  ).toBeDefined();
  await userEvent.keyboard("{Escape}");
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(document.activeElement).toBe(chip);
});

it("keeps per-calendar read failures visible next to the calendar board", async () => {
  const content = (calendarView?: typeof preview.calendarView) => (
    <CalendarPresentationProvider>
      <CalendarPage onCommand={command} state={{ ...preview, calendarView }} />
    </CalendarPresentationProvider>
  );
  const view = render(content());
  await waitFor(() =>
    expect(command).toHaveBeenCalledWith(
      expect.objectContaining({ action: "loadCalendarEvents" }),
    ),
  );
  const request = vi
    .mocked(command)
    .mock.calls.filter(([c]) => c.action === "loadCalendarEvents")
    .at(-1)![0];
  view.rerender(
    content({
      loaded: true,
      loading: false,
      start: String(request.start),
      end: String(request.end),
      events: [],
      errors: [
        {
          calendarIdentifier: preview.calendars[0].id,
          calendarName: "Fictional calendar",
          message: "Reconnect this account in Settings.",
        },
      ],
    }),
  );
  expect(await screen.findByRole("alert")).toHaveProperty(
    "textContent",
    expect.stringContaining("Reconnect this account in Settings."),
  );
  expect(screen.queryByText("Nothing scheduled this week.")).toBeNull();
  expect(screen.getByRole("button", { name: "Try again" })).toBeDefined();
});

it("starts calendar questions as a fresh task instead of continuing the previous chat", async () => {
  render(
    <CalendarPresentationProvider>
      <CalendarPage
        onCommand={command}
        state={{ ...preview, waitingApproval: false }}
      />
    </CalendarPresentationProvider>,
  );
  await userEvent.type(
    screen.getByRole("textbox", { name: "Ask Calshot about your calendar" }),
    "Find my events tomorrow",
  );
  await userEvent.click(
    screen.getByRole("button", { name: "Send calendar question" }),
  );
  expect(command).toHaveBeenCalledWith({
    action: "startCalendarTask",
    text: "Find my events tomorrow",
  });
  expect(vi.mocked(command).mock.calls.some(([c]) => c.action === "send")).toBe(
    false,
  );
});

it("navigates once per horizontal gesture, ignores momentum, and keeps vertical scrolling", async () => {
  const clock = vi.spyOn(performance, "now").mockReturnValue(1000);
  try {
    const view = render(
      <CalendarPresentationProvider>
        <CalendarPage onCommand={command} state={preview} />
      </CalendarPresentationProvider>,
    );
    const board = view.container.querySelector(".calendar-board")!;
    const firstDay = () =>
      screen
        .getAllByRole("button", { name: /^Open / })[0]
        .getAttribute("aria-label");
    const original = firstDay();
    fireEvent.wheel(board, { deltaX: 10, deltaY: 100 });
    fireEvent.wheel(board, { deltaX: 100, deltaY: 0 });
    expect(firstDay()).toBe(original); // A vertical gesture stays vertical.
    clock.mockReturnValue(1300);
    fireEvent.wheel(board, { deltaX: 40, deltaY: 2 });
    expect(firstDay()).toBe(original);
    fireEvent.wheel(board, { deltaX: 45, deltaY: 0 });
    const nextWeek = firstDay();
    expect(nextWeek).not.toBe(original);
    fireEvent.wheel(board, { deltaX: 300, deltaY: 0 });
    expect(firstDay()).toBe(nextWeek);
    clock.mockReturnValue(1700);
    fireEvent.wheel(board, { deltaX: -100, deltaY: 0 });
    expect(firstDay()).toBe(original);
    clock.mockReturnValue(2000);
    fireEvent.wheel(board, { deltaX: 200, ctrlKey: true });
    expect(firstDay()).toBe(original);
  } finally {
    clock.mockRestore();
  }
});

it("swipes by a day or month according to the selected view and leaves dialogs alone", async () => {
  const clock = vi.spyOn(performance, "now").mockReturnValue(1000);
  try {
    const view = render(
      <CalendarPresentationProvider>
        <CalendarPage
          onCommand={command}
          state={{ ...preview, waitingApproval: false }}
        />
      </CalendarPresentationProvider>,
    );
    const board = view.container.querySelector(".calendar-board")!;
    await userEvent.click(
      screen.getByRole("button", { name: "Day", exact: true }),
    );
    const label = () =>
      screen
        .getAllByRole("button", { name: /^Open / })[0]
        .getAttribute("aria-label");
    const original = label();
    fireEvent.wheel(board, { deltaX: 90 });
    expect(label()).not.toBe(original);
    clock.mockReturnValue(1400);
    fireEvent.wheel(board, { deltaX: -90 });
    expect(label()).toBe(original);
    await userEvent.click(
      screen.getByRole("button", { name: "Month", exact: true }),
    );
    const heading = screen.getByRole("heading", { level: 1 }).textContent;
    clock.mockReturnValue(1800);
    fireEvent.wheel(board, { deltaX: 90 });
    expect(screen.getByRole("heading", { level: 1 }).textContent).not.toBe(
      heading,
    );
    await userEvent.click(screen.getByRole("button", { name: "New event" }));
    const changed = screen.getByRole("heading", {
      level: 1,
      hidden: true,
    }).textContent;
    clock.mockReturnValue(2200);
    fireEvent.wheel(board, { deltaX: 90 });
    expect(
      screen.getByRole("heading", { level: 1, hidden: true }).textContent,
    ).toBe(changed);
  } finally {
    clock.mockRestore();
  }
});

it("shares a read-only calendar without offering unsupported web writes", async () => {
  render(
    <CalendarPresentationProvider>
      <CalendarPage
        state={{ ...preview, waitingApproval: false }}
        onCommand={command}
        readOnly
      />
    </CalendarPresentationProvider>,
  );
  await waitFor(() =>
    expect(command).toHaveBeenCalledWith(
      expect.objectContaining({ action: "loadCalendarEvents" }),
    ),
  );
  expect(screen.queryByRole("button", { name: "New event" })).toBeNull();
  expect(
    screen.queryByRole("textbox", { name: "Ask Calshot about your calendar" }),
  ).toBeNull();
  expect(
    screen
      .getByRole("link", { name: /Ask Calshot in the Mac app/ })
      .getAttribute("href"),
  ).toBe("calshot://");
  expect(screen.getByRole("button", { name: "Month" })).toBeTruthy();
});

it("resizes the native sidebar with bounded keyboard controls and reset", async () => {
  const onAction = vi.fn().mockResolvedValue(undefined);
  render(<Sidebar state={{ ...preview, native: true, sidebarExpanded: true, sidebarWidth: 312 }} onAction={onAction} />);
  const divider = screen.getByRole("separator", { name: "Resize sidebar" });
  fireEvent.keyDown(divider, { key: "ArrowRight" });
  expect(onAction).toHaveBeenLastCalledWith("sidebarWidth", { width: 320 });
  fireEvent.keyDown(divider, { key: "Home" });
  expect(onAction).toHaveBeenLastCalledWith("sidebarWidth", { width: 184 });
  fireEvent.doubleClick(divider);
  expect(onAction).toHaveBeenLastCalledWith("sidebarWidth", { width: 228 });
});

async function selectedPersonalEvent(readOnly = false) {
  const base = { ...preview, waitingApproval: false, running: false, saving: false, question: undefined, calendars: [{ ...preview.calendars[0], isReadOnly: true }] };
  const content = (state: typeof base) => <CalendarPresentationProvider><CalendarPage state={state} onCommand={command} readOnly={readOnly} /></CalendarPresentationProvider>;
  const rendered = render(content(base));
  await waitFor(() => expect(command).toHaveBeenCalledWith(expect.objectContaining({ action: "loadCalendarEvents" })));
  const request = vi.mocked(command).mock.calls.filter(([c]) => c.action === "loadCalendarEvents").at(-1)![0];
  const start = new Date(); start.setHours(10, 0, 0, 0);
  const selected = { ...event, title: "Fictional source event", calendarIdentifier: base.calendars[0].id, start: start.toISOString(), end: new Date(start.getTime() + 3600000).toISOString(), isAllDay: false, selectionHandle: "native-handle", selectionGeneration: "native-view" };
  const loaded = { ...base, calendarView: { loaded: true, loading: false, start: String(request.start), end: String(request.end), events: [selected], errors: [] } };
  rendered.rerender(content(loaded));
  fireEvent.click(screen.getByRole("button", { name: /Fictional source event/ }));
  return { rendered, content, loaded };
}
it("links a personal read-only source using only native authority and waits for the receipt", async () => {
  const { rendered, content, loaded } = await selectedPersonalEvent();
  fireEvent.click(screen.getByRole("button", { name: "Add to Tasks" }));
  await waitFor(() => expect(command).toHaveBeenCalledWith({ action: "linkCalendarEventTask", selectionHandle: "native-handle", selectionGeneration: "native-view" }));
  expect(screen.queryByText(/Added to Tasks on this Mac/)).toBeNull();
  rendered.rerender(content({ ...loaded, calendarTaskNotices: { "native-handle": { status: "success", receipt: { operationID: "operation", taskID: "task", taskVersion: "version", outcome: "saved", savedAt: "2026-10-23T00:00:00Z" } } } }));
  expect(screen.getByText(/Added to Tasks on this Mac/)).toBeDefined();
  expect(screen.getByRole("dialog", { name: "Fictional source event" })).toBeDefined();
  expect(screen.getByRole("button", { name: "View Tasks" })).toBeDefined();
  expect(vi.mocked(command).mock.calls.some(([c]) => c.action === "startCalendarTask")).toBe(false);
});
it("keeps link failures by the event and prevents concurrent repeated submissions", async () => {
  await selectedPersonalEvent();
  let reject!: (error: Error) => void;
  vi.mocked(command).mockImplementationOnce(() => new Promise((_, fail) => { reject = fail; }));
  const add = screen.getByRole("button", { name: "Add to Tasks" });
  fireEvent.click(add); fireEvent.click(add);
  expect(vi.mocked(command).mock.calls.filter(([c]) => c.action === "linkCalendarEventTask")).toHaveLength(1);
  reject(new Error("The source event changed. Select it again."));
  expect((await screen.findByRole("alert")).textContent).toContain("The source event changed");
  expect(screen.getByRole("dialog", { name: "Fictional source event" })).toBeDefined();
});
it("hides Add to Tasks on the read-only website", async () => {
  await selectedPersonalEvent(true);
  expect(screen.queryByRole("button", { name: "Add to Tasks" })).toBeNull();
});
it("keeps selected-event authority attached to its Calendar composer request", async () => {
  await selectedPersonalEvent();
  fireEvent.click(screen.getByRole("button", { name: "Ask Calshot about this" }));
  fireEvent.change(screen.getByRole("textbox", { name: "Ask Calshot about your calendar" }), { target: { value: "Add this event to Tasks" } });
  fireEvent.click(screen.getByRole("button", { name: "Send calendar question" }));
  await waitFor(() => expect(command).toHaveBeenCalledWith({ action: "startCalendarTask", text: "Add this event to Tasks", eventHandle: "native-handle", viewToken: "native-view" }));
});
it("discards the selected-event draft when its native view changes", async () => {
  const { rendered, content, loaded } = await selectedPersonalEvent();
  fireEvent.click(screen.getByRole("button", { name: "Ask Calshot about this" }));
  const input = screen.getByRole("textbox", { name: "Ask Calshot about your calendar" }) as HTMLInputElement;
  fireEvent.change(input, { target: { value: "Add this event to Tasks" } });
  rendered.rerender(content({ ...loaded, calendarView: { ...loaded.calendarView, events: [{ ...loaded.calendarView.events[0], selectionHandle: "new-handle", selectionGeneration: "new-generation" }] } }));
  await waitFor(() => expect(input.value).toBe(""));
});
