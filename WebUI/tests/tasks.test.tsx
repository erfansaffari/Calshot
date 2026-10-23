import { afterEach, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { TasksPage } from "../src/views/TasksPage";
import { HomeTasks } from "../src/components/HomeTasks";
import { preview } from "../src/preview";
import type { AppState, CalshotTask } from "../src/types";
afterEach(cleanup);
const task: CalshotTask = {
  id: "fixture-a",
  version: "v1",
  title: "Research assignment",
  dueDate: "2026-11-10",
  dueTime: "17:00",
  timeZone: "America/Toronto",
  notes: "Source: syllabus",
  completed: false,
  deleted: false,
  rank: 0,
  updatedAt: "2026-10-22T00:00:00Z",
};
function state(items: CalshotTask[] = [task]): AppState {
  return {
    ...preview,
    page: "tasks",
    proposals: [],
    saving: false,
    tasks: {
      loaded: true,
      busy: false,
      token: "current",
      items,
      deviceID: "this-mac",
    },
  };
}
it("creates a title-only Inbox task without inventing a date or reminder", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  render(<TasksPage state={state([])} onCommand={action} />);
  fireEvent.click(screen.getByRole("button", { name: "New task" }));
  fireEvent.change(screen.getByRole("textbox", { name: "Task" }), {
    target: { value: "Read the brief" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Save task" }));
  await waitFor(() =>
    expect(action).toHaveBeenCalledWith(
      expect.objectContaining({
        action: "saveTask",
        token: "current",
        title: "Read the brief",
        dueDate: null,
        dueTime: null,
        reminderMinutes: null,
      }),
    ),
  );
});
it("keeps an empty or whitespace title as a persistent field error without saving", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  render(<TasksPage state={state([])} onCommand={action} />);
  fireEvent.click(screen.getByRole("button", { name: "New task" }));
  const field = screen.getByRole("textbox", {
    name: "Task",
  }) as HTMLInputElement;
  const save = screen.getByRole("button", { name: "Save task" });
  save.focus();
  expect(document.activeElement).toBe(save);
  fireEvent.click(screen.getByRole("button", { name: "Save task" }));
  expect((await screen.findByRole("alert")).textContent).toContain(
    "Enter a task title.",
  );
  expect(field.getAttribute("aria-invalid")).toBe("true");
  expect(document.activeElement).toBe(field);
  fireEvent.change(field, { target: { value: "   " } });
  expect(screen.getByRole("alert").textContent).toContain(
    "Enter a task title.",
  );
  save.focus();
  expect(document.activeElement).toBe(save);
  fireEvent.click(save);
  expect(document.activeElement).toBe(field);
  expect(field.value).toBe("   ");
  expect(screen.getByRole("alert").textContent).toContain(
    "Enter a task title.",
  );
  expect(action).not.toHaveBeenCalled();
  fireEvent.change(field, { target: { value: "Read the brief" } });
  expect(screen.queryByRole("alert")).toBeNull();
  expect(field.getAttribute("aria-invalid")).toBe("false");
  fireEvent.click(screen.getByRole("button", { name: "Save task" }));
  await waitFor(() => expect(action).toHaveBeenCalledTimes(1));
});
it("sends the captured edit token and preserves unsaved text after a stale edit", async () => {
  const action = vi
    .fn()
    .mockRejectedValue(new Error("Tasks changed. Refresh and try again."));
  const view = render(<TasksPage state={state()} onCommand={action} />);
  fireEvent.click(screen.getByRole("button", { name: task.title }));
  fireEvent.change(screen.getByRole("textbox", { name: "Task" }), {
    target: { value: "My unsaved revision" },
  });
  view.rerender(
    <TasksPage
      state={{ ...state(), tasks: { ...state().tasks!, token: "newer" } }}
      onCommand={action}
    />,
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Save task & review deadline" }),
  );
  await waitFor(() =>
    expect(action).toHaveBeenCalledWith(
      expect.objectContaining({ action: "saveTask", token: "current" }),
    ),
  );
  expect(
    (screen.getByRole("textbox", { name: "Task" }) as HTMLInputElement).value,
  ).toBe("My unsaved revision");
  await waitFor(() =>
    expect(screen.getByRole("dialog").textContent).toContain("Tasks changed"),
  );
});
it("reorders with the current token without passing deadline fields", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  render(
    <TasksPage
      state={state([
        task,
        { ...task, id: "fixture-b", title: "Read chapter", rank: 1 },
      ])}
      onCommand={action}
    />,
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Move Research assignment down" }),
  );
  await waitFor(() =>
    expect(action).toHaveBeenCalledWith({
      action: "reorderTask",
      token: "current",
      taskID: "fixture-a",
      offset: 1,
    }),
  );
});
it("keeps calendar failures beside the saved task with an explicit review action", () => {
  render(
    <TasksPage
      state={state([
        { ...task, calendarError: "Calendar offline. Your task is saved." },
      ])}
      onCommand={vi.fn()}
    />,
  );
  expect(screen.getByRole("alert").textContent).toContain("Calendar offline");
  expect(screen.getByRole("button", { name: "Review deadline" })).toBeTruthy();
});
it("keeps the web view read-only with a Mac handoff", () => {
  render(<TasksPage state={state()} onCommand={vi.fn()} readOnly />);
  expect(screen.queryByRole("button", { name: "New task" })).toBeNull();
  expect((screen.getByRole("checkbox") as HTMLInputElement).disabled).toBe(
    true,
  );
  expect(
    screen.getByRole("link", { name: "Mac app" }).getAttribute("href"),
  ).toBe("calshot://");
});
it("opens archived tasks separately without calendar publication actions", () => {
  render(
    <TasksPage
      state={state([{ ...task, deleted: true }])}
      onCommand={vi.fn()}
    />,
  );
  expect(screen.queryByRole("button", { name: task.title })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Archived" }));
  expect(screen.getByRole("button", { name: "Restore" })).toBeTruthy();
  expect(screen.queryByRole("button", { name: "Review deadline" })).toBeNull();
});
it("shows dense rows with concise metadata and no filler header", () => {
  render(
    <TasksPage
      state={state([
        { ...task, dueDate: "2020-01-02", dueTime: undefined },
        {
          ...task,
          id: "fixture-b",
          title: "Read chapter",
          dueDate: undefined,
          dueTime: undefined,
          rank: 1,
        },
      ])}
      onCommand={vi.fn()}
    />,
  );
  expect(screen.queryByText("YOUR WORK, IN ORDER")).toBeNull();
  expect(screen.getByRole("heading", { name: "Tasks" })).toBeTruthy();
  expect(screen.getByText("2 open")).toBeTruthy();
  expect(screen.getByText(/Overdue · Jan 2, 2020/)).toBeTruthy();
  expect(screen.getByText("No date")).toBeTruthy();
  expect(screen.getAllByText("Not on calendar yet").length).toBe(1);
  expect(
    screen.getByRole("button", { name: "Archive Read chapter" }),
  ).toBeTruthy();
});
it("reveals editor fields progressively and keeps the draft when cancelling is not chosen", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  render(<TasksPage state={state([])} onCommand={action} />);
  expect(screen.getByRole("heading", { name: "No tasks yet" })).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "New task" }));
  expect(screen.queryByLabelText("Due time (optional)")).toBeNull();
  expect(screen.queryByLabelText("Deadline calendar")).toBeNull();
  expect(screen.queryByLabelText("Notes")).toBeNull();
  fireEvent.change(screen.getByLabelText("Due date"), {
    target: { value: "2026-12-01" },
  });
  expect(screen.getByLabelText("Due time (optional)")).toBeTruthy();
  expect(screen.getByLabelText("Deadline calendar")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: /Notes & reminder/ }));
  expect(screen.getByLabelText("Notes")).toBeTruthy();
  fireEvent.change(screen.getByLabelText("Remind on this Mac"), {
    target: { value: "60" },
  });
  expect(screen.getByLabelText("Reminder time")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(action).not.toHaveBeenCalled();
});
it("keeps the stale-edit reload action beside the editor", async () => {
  const action = vi.fn().mockRejectedValue(new Error("Tasks changed."));
  render(<TasksPage state={state()} onCommand={action} />);
  fireEvent.click(screen.getByRole("button", { name: task.title }));
  fireEvent.click(
    screen.getByRole("button", { name: "Save task & review deadline" }),
  );
  await waitFor(() =>
    expect(
      screen.getByRole("button", { name: "Reload current task" }),
    ).toBeTruthy(),
  );
});
it("shows confirmed deadlines from receipts and the other Mac's reminder", () => {
  const confirmed: CalshotTask = {
    ...task,
    calendarID: "cal",
    calendarName: "Personal",
    receipt: {
      eventIdentifier: "e",
      destinationID: "cal",
      calendarName: "Personal",
    },
    receiptDeviceID: "this-mac",
    publishedFingerprint: [
      task.title,
      task.dueDate,
      task.dueTime,
      task.timeZone,
      task.notes,
      "cal",
    ].join("\x1f"),
    reminderMinutes: 60,
    reminderDeviceID: "other-mac",
  };
  render(<TasksPage state={state([confirmed])} onCommand={vi.fn()} />);
  expect(screen.getByText("On Personal")).toBeTruthy();
  expect(screen.getByText(/1 hour before · source Mac/)).toBeTruthy();
  expect(screen.queryByRole("button", { name: "Review deadline" })).toBeNull();
});
const home = (
  items: CalshotTask[],
  extra: Partial<AppState> = {},
): AppState => ({
  ...state(items),
  page: "chat",
  ...extra,
});
it("summarizes overdue and next tasks on the Assistant home as navigation only", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  render(
    <HomeTasks
      state={home([
        {
          ...task,
          id: "later",
          title: "Later",
          dueDate: "2999-01-01",
          rank: 0,
        },
        {
          ...task,
          id: "late",
          title: "Late one",
          dueDate: "2020-01-01",
          rank: 2,
        },
        {
          ...task,
          id: "inbox",
          title: "Inbox one",
          dueDate: undefined,
          rank: 1,
        },
        { ...task, id: "done", title: "Finished", completed: true, rank: 3 },
        { ...task, id: "gone", title: "Archived", deleted: true, rank: 4 },
      ])}
      onCommand={action}
    />,
  );
  expect(screen.queryAllByRole("checkbox")).toHaveLength(0);
  expect(screen.queryByRole("textbox")).toBeNull();
  const rows = screen
    .getAllByRole("button")
    .filter((b) => b.className.includes("home-task"));
  expect(
    rows.map((r) => r.querySelector(".home-task-title")?.textContent),
  ).toEqual(["Late one", "Later", "Inbox one"]);
  expect(screen.getByText("3 open")).toBeTruthy();
  expect(screen.getByText("1 overdue")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "View all" }));
  await waitFor(() => expect(action).toHaveBeenCalledTimes(1));
  await waitFor(() =>
    expect((rows[0] as HTMLButtonElement).disabled).toBe(false),
  );
  fireEvent.click(rows[0]);
  await waitFor(() => expect(action).toHaveBeenCalledTimes(2));
  expect(action.mock.calls.map(([c]) => c)).toEqual([
    { action: "navigate", page: "tasks" },
    { action: "navigate", page: "tasks" },
  ]);
});
it("keeps a failed home navigation visible beside the summary", async () => {
  const action = vi.fn().mockRejectedValue(new Error("Couldn’t open Tasks."));
  render(<HomeTasks state={home([task])} onCommand={action} />);
  fireEvent.click(screen.getByRole("button", { name: "View all" }));
  await waitFor(() =>
    expect(screen.getByText("Couldn’t open Tasks.")).toBeTruthy(),
  );
});
it("offers Open Tasks instead of an inline form when nothing is open", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  render(<HomeTasks state={home([])} onCommand={action} />);
  expect(screen.getByText("No open tasks.")).toBeTruthy();
  expect(screen.queryByRole("textbox")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Open Tasks" }));
  await waitFor(() =>
    expect(action).toHaveBeenCalledWith({ action: "navigate", page: "tasks" }),
  );
  expect(action).toHaveBeenCalledTimes(1);
});
it("shows no home summary before native tasks exist and a loading state while reading", () => {
  const view = render(
    <HomeTasks state={{ ...home([]), tasks: undefined }} onCommand={vi.fn()} />,
  );
  expect(view.container.firstChild).toBeNull();
  cleanup();
  render(
    <HomeTasks
      state={{ ...home([]), tasks: { ...state([]).tasks!, loaded: false } }}
      onCommand={vi.fn()}
    />,
  );
  expect(screen.getByText(/Loading your tasks/)).toBeTruthy();
  expect(screen.queryByRole("textbox")).toBeNull();
});

it("keeps source-linked tasks task-only while editing their own dates and reminders", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  const linked: CalshotTask = { ...task, calendarIntent: "existing", intentProvenance: "explicit", sourceLink: { deviceID: "this-mac", calendarID: "school", eventID: "source-event", occurrenceKey: "single", observedStart: "2026-11-10T22:00:00Z", observedEnd: "2026-11-10T23:00:00Z", observedAt: "2026-10-23T00:00:00Z", calendarName: "Fictional school", sourceName: "Fixture" } };
  render(<TasksPage state={state([linked])} onCommand={action} />);
  expect(screen.queryByRole("button", { name: "Review deadline" })).toBeNull();
  expect(screen.getByText(/Linked to source/)).toBeDefined();
  fireEvent.click(screen.getByRole("button", { name: task.title }));
  expect(screen.queryByRole("combobox", { name: "Calendar use" })).toBeNull();
  expect(screen.queryByRole("combobox", { name: "Deadline calendar" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Save task" }));
  await waitFor(() => expect(action).toHaveBeenCalled());
  const save = action.mock.calls.find(([c]) => c.action === "saveTask")![0];
  expect(save).not.toHaveProperty("calendarIntent");
  expect(save).not.toHaveProperty("calendarID");
});
it("sends Tasks-only intent only after an explicit choice and needs no writable calendar", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  render(<TasksPage state={{ ...state(), calendars: [], selectedCalendarID: undefined }} onCommand={action} />);
  fireEvent.click(screen.getByRole("button", { name: task.title }));
  fireEvent.change(screen.getByRole("combobox", { name: "Calendar use" }), { target: { value: "none" } });
  fireEvent.click(screen.getByRole("button", { name: "Save task" }));
  await waitFor(() => expect(action).toHaveBeenCalledWith(expect.objectContaining({ action: "saveTask", calendarIntent: "none", dueDate: task.dueDate })));
  expect(action.mock.calls[0][0]).not.toHaveProperty("calendarID");
});
it("preserves omitted intent for ordinary edits and locks owned publication transitions", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  const published = { ...task, calendarIntent: "new" as const, intentProvenance: "explicit" as const, receiptDeviceID: "this-mac", receipt: { eventIdentifier: "owned", destinationID: "school", calendarName: "School" } };
  render(<TasksPage state={state([published])} onCommand={action} />);
  fireEvent.click(screen.getByRole("button", { name: task.title }));
  expect(screen.queryByRole("combobox", { name: "Calendar use" })).toBeNull();
  expect(screen.getByText(/retain or remove that entry/)).toBeDefined();
  fireEvent.click(screen.getByRole("button", { name: "Save task & review deadline" }));
  await waitFor(() => expect(action).toHaveBeenCalled());
  expect(action.mock.calls[0][0]).not.toHaveProperty("calendarIntent");
});
it("does not offer deadline review for Tasks-only dated tasks", () => {
  render(<TasksPage state={state([{ ...task, calendarIntent: "none", intentProvenance: "explicit" }])} onCommand={async () => {}} />);
  expect(screen.queryByRole("button", { name: "Review deadline" })).toBeNull();
  expect(screen.queryByText("Not on calendar yet")).toBeNull();
});
