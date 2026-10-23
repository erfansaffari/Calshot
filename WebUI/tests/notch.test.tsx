import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor, fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { preview } from "../src/preview";
import type { AppState } from "../src/types";
const mock = vi.hoisted(() => ({ state: {} as AppState, command: vi.fn().mockResolvedValue(undefined) }));
vi.mock("../src/bridge", () => ({ useAppState: () => mock.state, command: mock.command }));
import NotchApp from "../src/NotchApp";
beforeEach(() => { mock.state = structuredClone(preview); mock.command.mockClear(); });
afterEach(cleanup);
it("imports an unannotated screenshot through a distinct native action", async () => {
  mock.state.imageURL = "fixture://capture"; mock.state.messages = []; mock.state.proposals = [];
  mock.state.running = false; mock.state.saving = false; mock.state.isRecognizing = false; mock.state.isCapturing = false;
  render(<NotchApp />);
  await userEvent.click(screen.getByRole("button", { name: "Add to calendar", exact: true }));
  expect(mock.command).toHaveBeenCalledWith({ action: "importCapturedScreenshot" });
  expect(mock.command.mock.calls.some(([c]) => c.action === "send")).toBe(false);
});
it("keeps user-written screenshot instructions as a typed request", async () => {
  mock.state.imageURL = "fixture://capture"; mock.state.messages = []; mock.state.proposals = [];
  mock.state.running = false; mock.state.saving = false; mock.state.isRecognizing = false; mock.state.isCapturing = false;
  render(<NotchApp />);
  await userEvent.type(screen.getByRole("textbox", { name: "Screenshot instructions" }), "Add this to Tasks only");
  await userEvent.click(screen.getByRole("button", { name: "Add to calendar", exact: true }));
  expect(mock.command).toHaveBeenCalledWith({ action: "send", text: "Add this to Tasks only" });
});
it("answers the current question inside the notch without opening the workspace", async () => {
  mock.state.question = { id: "question-in-notch", question: "Which class?", choices: ["Biology", "Chemistry"] };
  render(<NotchApp />);
  await userEvent.click(screen.getByRole("button", { name: "Chemistry" }));
  expect(mock.command).toHaveBeenCalledWith({ action: "answer", questionID: "question-in-notch", answer: "Chemistry" });
  expect(mock.command.mock.calls.some(([c]) => c.action === "openWorkspace")).toBe(false);
});
it("only offers Add all for a clean create batch and binds approval to its token", async () => {
  mock.state.proposals.forEach(p => { p.operation = "create"; p.isSelected = true; p.isApprovable = true; p.state = "pending"; });
  mock.state.canApprove = true;
  render(<NotchApp />);
  await userEvent.click(screen.getByRole("button", { name: "Add all" }));
  expect(mock.command).toHaveBeenCalledWith({ action: "approve", token: mock.state.approvalToken });
});
it("keeps removals unchecked in inline review and never offers a quick write", async () => {
  mock.state.proposals = [{ ...mock.state.proposals[0], operation: "delete", isSelected: false }];
  render(<NotchApp />);
  expect(screen.queryByRole("button", { name: "Add all" })).toBeNull();
  await userEvent.click(screen.getByRole("button", { name: "Review" }));
  expect((screen.getByRole("checkbox") as HTMLInputElement).checked).toBe(false);
  await waitFor(() => expect(mock.command).toHaveBeenCalledWith(expect.objectContaining({ action: "notchLayout", detail: true })));
});
it("shows the assistant reply and supports follow-up without a workspace navigation", async () => {
  mock.state.proposals = [];
  mock.state.messages = [{ role: "assistant", content: "Both classes are on Friday." }];
  mock.state.running = false;
  render(<NotchApp />);
  expect(screen.queryByText("Both classes are on Friday.")).toBeNull();
  await userEvent.click(screen.getByRole("button", { name: "View conversation" }));
  expect(screen.getByText("Both classes are on Friday.")).toBeDefined();
  fireEvent(window, new Event("calshot:notch-collapsed"));
  expect(screen.queryByText("Both classes are on Friday.")).toBeNull();
  expect(screen.getByRole("button", { name: "Capture" })).toBeDefined();
  await userEvent.type(screen.getByRole("textbox", { name: "Ask Calshot" }), "Move them to Monday");
  await userEvent.click(screen.getByRole("button", { name: "Send message" }));
  expect(mock.command).toHaveBeenCalledWith({ action: "send", text: "Move them to Monday" });
});
it("closes the editor with Escape while preserving the review and focus", async () => {
  mock.state.proposals = [{ ...mock.state.proposals[0], operation: "create" }];
  render(<NotchApp />);
  await userEvent.click(screen.getByRole("button", { name: "Review" }));
  const edit = screen.getByRole("button", { name: "Edit " + mock.state.proposals[0].draft.title });
  await userEvent.click(edit);
  expect(screen.getByRole("dialog")).toBeDefined();
  await userEvent.keyboard("{Escape}");
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(screen.getByRole("button", { name: "Hide review" })).toBeDefined();
});

it("preserves unfinished event edits when pointer leave hides the notch", async () => {
  mock.state.proposals = [{ ...mock.state.proposals[0], operation: "create" }];
  render(<NotchApp />);
  await userEvent.click(screen.getByRole("button", { name: "Review" }));
  await userEvent.click(screen.getByRole("button", { name: "Edit " + mock.state.proposals[0].draft.title }));
  const title = screen.getByRole("textbox", { name: "Event title" });
  await userEvent.clear(title);
  await userEvent.type(title, "Unfinished corrected title");
  fireEvent(window, new Event("calshot:notch-collapsed"));
  expect(screen.getByRole("dialog")).toBeDefined();
  expect((screen.getByRole("textbox", { name: "Event title" }) as HTMLInputElement).value).toBe("Unfinished corrected title");
  expect(mock.command.mock.calls.some(([c]) => ["approve", "skip", "editProposal", "stop"].includes(c.action))).toBe(false);
});
