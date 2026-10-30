import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { preview, previewTaskRows } from "../src/preview";
import type { AppState, TaskReview } from "../src/types";
const mock = vi.hoisted(() => ({ state: {} as AppState, command: vi.fn().mockResolvedValue(undefined) }));
vi.mock("../src/bridge", () => ({ useAppState: () => mock.state, command: mock.command, notify: vi.fn() }));
import App from "../src/App";
import NotchApp from "../src/NotchApp";
import { SettingsPage } from "../src/views/Pages";
import { TaskChangeReview, TaskOutcomeCard } from "../src/components/TaskChangeReview";

const review = (count: number, extra: Partial<TaskReview> = {}): TaskReview => ({
  id: "review-1", token: "token-1", digest: "digest-1", kind: "complete", phase: "waiting", calendarWrites: 0,
  reason: "No current permission for this action and invocation.", heading: `Mark complete: ${count} tasks`,
  rows: previewTaskRows(count), ...extra,
});
const base = (): AppState => {
  const state = structuredClone(preview);
  state.running = true; state.proposals = []; state.waitingApproval = false; state.canApprove = false; state.selectedCount = 0;
  state.messages = [{ role: "user", content: "Mark my reading tasks complete." }];
  return state;
};
beforeEach(() => { mock.state = base(); mock.command.mockReset(); mock.command.mockResolvedValue(undefined); });
afterEach(cleanup);

describe("Task-only review in the conversation", () => {
  it("shows the real before/after, states that the calendar is untouched and binds approval to the review", async () => {
    mock.state.taskReview = review(2);
    render(<App />);
    const region = screen.getByRole("region", { name: "Task change review" });
    expect(within(region).getByRole("heading", { name: "Mark complete: 2 tasks" })).toBeTruthy();
    expect(within(region).getAllByText("Open")).toHaveLength(2);
    expect(within(region).getAllByText("Complete")).toHaveLength(2);
    expect(within(region).getByText("Your calendar isn’t changed.")).toBeTruthy();
    expect(within(region).getByText(/allow routine ones in Settings/)).toBeTruthy();
    // Calendar approval controls are never involved.
    expect(screen.queryByRole("button", { name: /Add all|Approve/ })).toBeNull();
    await userEvent.click(within(region).getByRole("button", { name: "Save changes" }));
    expect(mock.command).toHaveBeenCalledWith({ action: "approveTaskChange", reviewID: "review-1", token: "token-1", digest: "digest-1" });
  });

  it("explains a screenshot-started review and keeps the idle copy precise", () => {
    mock.state.taskReview = review(1, { reason: "A screenshot started this request, so Calshot asks before changing your tasks." });
    render(<App />);
    expect(screen.getByText(/A screenshot started this, so Calshot asks/)).toBeTruthy();
    expect(screen.queryByText("Nothing changes without your approval")).toBeNull();
  });

  it("declines with the same review identity and never sends a digest", async () => {
    mock.state.taskReview = review(1);
    render(<App />);
    await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(mock.command).toHaveBeenCalledWith({ action: "cancelTaskChange", reviewID: "review-1", token: "token-1" });
  });

  it("keeps the review usable and shows a stale-click error next to it", async () => {
    mock.command.mockRejectedValueOnce(new Error("This task review is no longer current."));
    mock.state.taskReview = review(1);
    render(<App />);
    await userEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect((await screen.findByRole("alert")).textContent).toContain("no longer current");
    expect((screen.getByRole("button", { name: "Save changes" }) as HTMLButtonElement).disabled).toBe(false);
  });

  it("ignores a second click while applying and approves once with Command+Return", async () => {
    mock.state.taskReview = review(1);
    render(<App />);
    const region = screen.getByRole("region", { name: "Task change review" });
    fireEvent.keyDown(region, { key: "Enter", metaKey: true });
    fireEvent.keyDown(region, { key: "Enter", metaKey: true });
    expect(mock.command.mock.calls.filter(([c]) => c.action === "approveTaskChange")).toHaveLength(1);
    cleanup();
    mock.state.taskReview = review(1, { phase: "applying" });
    render(<App />);
    const saving = screen.getByRole("button", { name: /Saving/ }) as HTMLButtonElement;
    expect(saving.disabled).toBe(true);
    expect((screen.getByRole("button", { name: "Cancel" }) as HTMLButtonElement).disabled).toBe(true);
  });

  it("keeps twelve long rows reachable by keyboard and removes stale buttons when the run ends", () => {
    mock.state.taskReview = review(12);
    const view = render(<App />);
    const list = screen.getByRole("list", { name: "Task changes" });
    expect(within(list).getAllByRole("listitem")).toHaveLength(12);
    expect(list.getAttribute("tabindex")).toBe("0");
    mock.state = { ...mock.state, taskReview: undefined, running: false };
    view.rerender(<App />);
    expect(screen.queryByRole("button", { name: "Save changes" })).toBeNull();
  });

  it("reports a partial result per row with the error beside the affected task", () => {
    render(<TaskOutcomeCard outcome={{ id: "o", status: "partial", headline: "1 of 3 saved", viaSavedPermission: false, rows: [
      { id: "a", title: "Read chapter 1", status: "saved" },
      { id: "b", title: "Read chapter 2", status: "failed", message: "Finish or skip this task’s deadline review first." },
      { id: "c", title: "Read chapter 3", status: "cancelled", message: "Stopped before this change was saved." }] }} />);
    const status = screen.getByRole("status", { name: "Task result" });
    expect(within(status).getByText("1 of 3 saved")).toBeTruthy();
    const failed = within(status).getByText("Read chapter 2").closest("li")!;
    expect(within(failed).getByRole("alert").textContent).toContain("deadline review");
    expect(within(failed).getByText("Not saved")).toBeTruthy();
    expect(within(status).getByText("Stopped")).toBeTruthy();
    expect(within(status).queryByText("Allowed in Settings")).toBeNull();
  });

  it("shows a saved-permission result without a review", () => {
    mock.state.running = false;
    mock.state.taskOutcome = { id: "o", status: "saved", headline: "Task updated", viaSavedPermission: true, rows: [{ id: "a", title: "Read chapter 1", status: "saved" }] };
    render(<App />);
    expect(screen.queryByRole("region", { name: "Task change review" })).toBeNull();
    expect(screen.getByText("Allowed in Settings")).toBeTruthy();
  });
});

describe("Task-only review in the compact notch", () => {
  it("answers inside the notch without opening the workspace and offers Stop", async () => {
    mock.state.taskReview = review(2);
    render(<NotchApp />);
    expect(screen.getByRole("status").textContent).toContain("Review task change");
    await userEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(mock.command).toHaveBeenCalledWith({ action: "approveTaskChange", reviewID: "review-1", token: "token-1", digest: "digest-1" });
    await userEvent.click(screen.getByRole("button", { name: "Stop task" }));
    expect(mock.command).toHaveBeenCalledWith({ action: "stop" });
    expect(mock.command.mock.calls.some(([c]) => c.action === "openWorkspace")).toBe(false);
    expect(screen.queryByText(/allow routine ones in Settings/)).toBeNull();
    await waitFor(() => expect(mock.command).toHaveBeenCalledWith(expect.objectContaining({ action: "notchLayout", detail: true })));
  });

  it("shows a concise dismissible result once the run is finished", async () => {
    mock.state.running = false;
    mock.state.taskOutcome = { id: "o", status: "saved", headline: "Added to Tasks", viaSavedPermission: false, rows: [{ id: "a", title: "Studio critique", status: "saved" }] };
    render(<NotchApp />);
    expect(screen.getByText("Added to Tasks")).toBeTruthy();
    await userEvent.click(screen.getByRole("button", { name: "Hide details" }));
    expect(screen.queryByText("Added to Tasks")).toBeNull();
  });

  it("never mixes with the calendar review controls", () => {
    mock.state.taskReview = review(12);
    render(<NotchApp />);
    expect(screen.queryByRole("button", { name: /Add all|Review$/ })).toBeNull();
    expect(screen.getAllByRole("listitem")).toHaveLength(12);
  });
});

describe("Settings task permissions", () => {
  const settings = () => {
    mock.state = structuredClone(preview);
    mock.state.page = "settings"; mock.state.settingsSection = "privacy";
    const view = render(<SettingsPage state={mock.state} />);
    fireEvent.click(screen.getByRole("button", { name: "Customize" }));
    return view;
  };
  it("one autonomy switch saves every routine action against the current revision", async () => {
    mock.state = structuredClone(preview); mock.state.page = "settings"; mock.state.settingsSection = "privacy";
    render(<SettingsPage state={mock.state} />);
    const toggle = screen.getByRole("switch", { name: /Let Calshot act without asking/ });
    expect(toggle.getAttribute("aria-checked")).toBe("false");
    expect(screen.queryByRole("heading", { name: "Task actions" })).toBeNull(); // details stay behind Customize
    await userEvent.click(toggle);
    expect(mock.command).toHaveBeenCalledWith({ action: "saveAutonomy", revision: mock.state.agentPermissions!.revision, enabled: true });
  });

  it("starts with nothing enabled, no background control and no reorder promise", () => {
    settings();
    const boxes = within(screen.getByRole("heading", { name: "Task actions" }).closest("section")!).getAllByRole("checkbox") as HTMLInputElement[];
    expect(boxes).toHaveLength(5);
    expect(boxes.every((box) => !box.checked)).toBe(true);
    expect(screen.queryByText(/Reorder/)).toBeNull(); // only implemented grant families appear
    expect(screen.queryByRole("checkbox", { name: /background/i })).toBeNull();
    const calendar = screen.getByRole("heading", { name: "Calendar actions" }).closest("section")!;
    expect(within(calendar).getAllByText("Always asks")).toHaveLength(2); // delete and move have no switch
    expect(within(calendar).getByRole("checkbox", { name: "Add new events" })).toHaveProperty("checked", false);
    expect(within(calendar).getByRole("checkbox", { name: "Edit event details" })).toHaveProperty("checked", false);
    expect((screen.getByRole("button", { name: "Save task permissions" }) as HTMLButtonElement).disabled).toBe(true);
    expect(mock.command).toHaveBeenCalledWith({ action: "loadAgentPermissions" });
  });

  it("saves only an explicit choice against the current revision", async () => {
    settings();
    await userEvent.click(screen.getByRole("checkbox", { name: "Edit tasks" }));
    await userEvent.click(screen.getByRole("checkbox", { name: "Complete or reopen tasks" }));
    await userEvent.selectOptions(screen.getByRole("combobox", { name: "Allow for" }), "7");
    await userEvent.click(screen.getByRole("button", { name: "Save task permissions" }));
    expect(mock.command).toHaveBeenCalledWith({
      action: "saveAgentPermissions", revision: 0, days: 7, renew: true,
      families: { create: false, link: false, edit: true, complete: true, archive: false },
    });
  });

  it("treats choosing a period for an active action as an explicit renewal", async () => {
    mock.state = structuredClone(preview);
    mock.state.agentPermissions!.families[2] = { ...mock.state.agentPermissions!.families[2], enabled: true };
    mock.state.agentPermissions!.expiresAt = "2026-11-02T12:00:00Z";
    render(<SettingsPage state={{ ...mock.state, page: "settings", settingsSection: "privacy" }} />); fireEvent.click(screen.getByRole("button", { name: "Customize" }));
    const save = screen.getByRole("button", { name: "Save task permissions" }) as HTMLButtonElement;
    expect(save.disabled).toBe(true);
    await userEvent.selectOptions(screen.getByRole("combobox", { name: "Allow for" }), "90");
    expect(save.disabled).toBe(false);
    await userEvent.click(save);
    expect(mock.command).toHaveBeenCalledWith(expect.objectContaining({ action: "saveAgentPermissions", days: 90, renew: true }));
  });

  it("does not renew an existing period when only another switch changes", async () => {
    mock.state = structuredClone(preview);
    mock.state.agentPermissions!.families[2] = { ...mock.state.agentPermissions!.families[2], enabled: true };
    render(<SettingsPage state={{ ...mock.state, page: "settings", settingsSection: "privacy" }} />); fireEvent.click(screen.getByRole("button", { name: "Customize" }));
    await userEvent.click(screen.getByRole("checkbox", { name: "Complete or reopen tasks" }));
    await userEvent.click(screen.getByRole("button", { name: "Save task permissions" }));
    expect(mock.command).toHaveBeenCalledWith(expect.objectContaining({ action: "saveAgentPermissions", renew: false }));
  });

  it("shows a native save error beside the Save button and keeps the draft", async () => {
    mock.command.mockImplementation(async (c: { action: string }) => { if (c.action === "saveAgentPermissions") throw new Error("Permissions changed on this Mac. Check the latest settings and save again."); });
    settings();
    await userEvent.click(screen.getByRole("checkbox", { name: "Add tasks" }));
    await userEvent.click(screen.getByRole("button", { name: "Save task permissions" }));
    expect((await screen.findByRole("alert")).textContent).toContain("Permissions changed on this Mac");
    expect((screen.getByRole("checkbox", { name: "Add tasks" }) as HTMLInputElement).checked).toBe(true);
  });

  it("pauses controls with a persistent error when the permission store cannot be opened", () => {
    mock.state = structuredClone(preview);
    mock.state.agentPermissions = { ...mock.state.agentPermissions!, loaded: false, error: "Saved task permissions couldn’t be read safely. The file was kept and task changes by Calshot are paused." };
    render(<SettingsPage state={{ ...mock.state, page: "settings", settingsSection: "privacy" }} />); fireEvent.click(screen.getByRole("button", { name: "Customize" }));
    expect(screen.getAllByRole("alert").every((alert) => alert.textContent?.includes("task changes by Calshot are paused"))).toBe(true);
    expect(screen.getAllByRole("checkbox").every((box) => (box as HTMLInputElement).disabled)).toBe(true);
    expect((screen.getByRole("button", { name: "Save task permissions" }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole("button", { name: "Save calendar permissions" }) as HTMLButtonElement).disabled).toBe(true);
  });

  it("saves calendar permissions with the checked writable calendars", async () => {
    settings();
    const calendar = screen.getByRole("heading", { name: "Calendar actions" }).closest("section")!;
    await userEvent.click(within(calendar).getByRole("checkbox", { name: "Add new events" }));
    const save = within(calendar).getByRole("button", { name: "Save calendar permissions" }) as HTMLButtonElement;
    const scope = mock.state.selectedCalendarID ? [mock.state.selectedCalendarID] : [];
    if (!scope.length) { expect(save.disabled).toBe(true); return; } // no writable calendar chosen yet
    await userEvent.click(save);
    expect(mock.command).toHaveBeenCalledWith(expect.objectContaining({ action: "saveCalendarPermissions", families: { create: true, edit: false }, calendarIDs: scope, days: 30, renew: false }));
  });

  it("adopts a newer native revision and flags an expired grant instead of silently enabling it", () => {
    mock.state = structuredClone(preview);
    mock.state.agentPermissions!.families[2] = { ...mock.state.agentPermissions!.families[2], expired: true };
    render(<SettingsPage state={{ ...mock.state, page: "settings", settingsSection: "privacy" }} />); fireEvent.click(screen.getByRole("button", { name: "Customize" }));
    expect(screen.getByText(/Earlier permission expired/)).toBeTruthy();
    expect((screen.getByRole("checkbox", { name: "Edit tasks" }) as HTMLInputElement).checked).toBe(false);
  });
});

it("renders a review standalone with long single-row content", () => {
  render(<TaskChangeReview review={review(1, { rows: [{ id: "r", title: "A".repeat(300), changes: [{ label: "Notes", before: "None", after: "B".repeat(160) }] }] })} />);
  expect(screen.getByRole("region", { name: "Task change review" })).toBeTruthy();
});
