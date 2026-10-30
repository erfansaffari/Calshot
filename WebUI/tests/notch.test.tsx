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
function voiceFixture() {
  mock.state.proposals = []; mock.state.messages = []; mock.state.running = false; mock.state.waitingApproval = false;
  mock.state.voice = { token: "voice-current", state: "listening", active: true, inputLevel: .5, caption: "", userTranscript: "", drawing: false, usage: { seconds: 12, estimatedCost: .03 }, needsKey: false, needsAcknowledgement: false, permissions: { microphone: true, screen: true }, model: "fictional-model", voice: "marin", monthlyCap: 10 };
}
it("holds to talk: press uses the session token, release does not need it", async () => {
  voiceFixture(); mock.state.voice!.shortcut = "⌃⇧V"; render(<NotchApp />);
  expect(screen.queryByRole("meter")).toBeNull(); expect(screen.getByText("Hold ⌃⇧V to talk")).toBeTruthy();
  const talk = screen.getByRole("button", { name: "Hold to talk" });
  fireEvent.pointerDown(talk, { button: 0, pointerId: 1 }); fireEvent.pointerUp(talk, { pointerId: 1 });
  expect(mock.command).toHaveBeenCalledWith({ action: "voiceTalk", token: "voice-current", pressed: true });
  expect(mock.command).toHaveBeenCalledWith({ action: "voiceTalk", pressed: false });
});
it("shows live voice level while talking and stops with its current session token", async () => {
  voiceFixture(); mock.state.voice!.talking = true; render(<NotchApp />);
  expect(screen.getByRole("meter").getAttribute("aria-valuenow")).toBe("0.5"); expect(screen.getByText("Listening")).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "Stop", exact: true }));
  expect(mock.command).toHaveBeenCalledWith({ action: "stopVoice", token: "voice-current" });
});
it("shows speaking captions and a voice billing acknowledgement inline", async () => {
  voiceFixture(); mock.state.voice!.state = "speaking"; mock.state.voice!.caption = "Fictional appointment at noon.";
  mock.state.voice!.needsAcknowledgement = true;
  render(<NotchApp />); expect(screen.getByText("Speaking")).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "Voice details" }));
  expect(screen.getByText("Fictional appointment at noon.")).toBeTruthy();
  await userEvent.click(screen.getByText("I understand"));
  expect(mock.command).toHaveBeenCalledWith({ action: "acknowledgeVoiceBilling", token: "voice-current" });
});
it("Escape ends voice without approving the review", async () => {
  voiceReview(); render(<NotchApp />); fireEvent.keyDown(window, { key: "Escape" });
  await waitFor(() => expect(mock.command).toHaveBeenCalledWith({ action: "stopVoice", token: "voice-current" }));
  expect(mock.command.mock.calls.some(([c]) => c.action === "approve")).toBe(false);
});
function voiceReview() {
  const proposals = mock.state.proposals;
  voiceFixture(); mock.state.proposals = proposals; mock.state.waitingApproval = true; mock.state.canApprove = true;
  proposals.forEach(p => { p.operation = "create"; p.isSelected = true; p.isApprovable = true; p.state = "pending"; p.inScope = true; p.isFinished = false; });
}
it("Return requires a visible clean review and ignores repeats, controls, and replacement tokens", async () => {
  voiceReview(); const view = render(<NotchApp />);
  fireEvent.keyDown(window, { key: "Enter" });
  expect(mock.command.mock.calls.some(([c]) => c.action === "approve")).toBe(false);
  await userEvent.click(screen.getByRole("button", { name: "Review", exact: true }));
  fireEvent.keyDown(window, { key: "Enter", repeat: true });
  fireEvent.keyDown(screen.getByRole("textbox", { name: "Follow-up message" }), { key: "Enter" });
  expect(mock.command.mock.calls.some(([c]) => c.action === "approve")).toBe(false);
  fireEvent.keyDown(window, { key: "Enter" });
  expect(mock.command.mock.calls.filter(([c]) => c.action === "approve")).toHaveLength(1);
  mock.state = { ...mock.state, approvalToken: "replacement" }; view.rerender(<NotchApp />);
  fireEvent.keyDown(window, { key: "Enter" });
  expect(mock.command.mock.calls.filter(([c]) => c.action === "approve")).toHaveLength(1);
});
it.each(["update", "delete", "move"] as const)("Return never approves %s", async operation => {
  voiceReview(); mock.state.proposals.forEach(p => { p.operation = operation; }); render(<NotchApp />);
  await userEvent.click(screen.getByRole("button", { name: "Review", exact: true }));
  fireEvent.keyDown(window, { key: "Enter" });
  expect(mock.command.mock.calls.some(([c]) => c.action === "approve")).toBe(false);
});
it("shows screen access while voice frames may be captured", () => {
  voiceFixture(); render(<NotchApp />); expect(screen.getByRole("img", { name: "Calshot can see your screen" })).toBeTruthy();
});
it("offers only token-bound approval and dismissal for pending memory in voice", async () => {
  voiceFixture(); mock.state.personalMemory = { loaded: true, items: [], token: "memory-current", pending: [{ id: "suggestion", version: "version", kind: "preference", text: "Fictional memory", origin: "suggested", status: "pendingApproval", createdAt: "2026-10-29", updatedAt: "2026-10-29" }] };
  render(<NotchApp />); await userEvent.click(screen.getByText("Remember this"));
  expect(mock.command).toHaveBeenCalledWith({ action: "approveMemory", token: "memory-current", memoryID: "suggestion", expectedVersion: "version" });
  await userEvent.click(screen.getByText("Dismiss suggestion"));
  expect(mock.command).toHaveBeenCalledWith({ action: "rejectMemory", token: "memory-current", memoryID: "suggestion", expectedVersion: "version", dontSuggestAgain: false });
});
it("Return never approves a visible task change review", () => {
  voiceFixture(); mock.state.taskReview = { id: "task-review", token: "task-token", digest: "digest", kind: "edit", heading: "Review task change", phase: "waiting", reason: "Voice requires review", calendarWrites: 0, rows: [{ id: "task", title: "Fictional task", changes: [{ label: "Title", before: "Before", after: "After" }] }] };
  render(<NotchApp />); expect(screen.getByText("Fictional task")).toBeTruthy(); fireEvent.keyDown(window, { key: "Enter" });
  expect(mock.command.mock.calls.some(([c]) => c.action === "approveTaskChange")).toBe(false);
});
