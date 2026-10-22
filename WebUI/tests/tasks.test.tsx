import { afterEach, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { TasksPage } from "../src/views/TasksPage";
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
