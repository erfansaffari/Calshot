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
  expect(screen.getByRole("button", { name: "Hide review" })).toBeTruthy();
  expect((screen.getByRole("checkbox") as HTMLInputElement).checked).toBe(false);
  await waitFor(() => expect(mock.command).toHaveBeenCalledWith(expect.objectContaining({ action: "notchLayout", detail: true })));
});
it("keeps conversation text out of the notch and supports follow-up without navigation", async () => {
  mock.state.proposals = [];
  mock.state.messages = [{ role: "assistant", content: "Both classes are on Friday." }];
  mock.state.running = false;
  render(<NotchApp />);
  expect(screen.queryByText("Both classes are on Friday.")).toBeNull();
  expect(screen.queryByRole("button", { name: "View conversation" })).toBeNull();
  expect(screen.queryByLabelText("Calendar conversation")).toBeNull();
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
  expect(screen.getByRole("button", { name: "Hide review" })).toBeTruthy();
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
  expect(screen.getByRole("button", { name: "Hide review" })).toBeTruthy();
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
it("keeps voice captions hidden while showing the billing acknowledgement", async () => {
  voiceFixture(); mock.state.voice!.state = "speaking"; mock.state.voice!.caption = "Fictional appointment at noon.";
  mock.state.voice!.needsAcknowledgement = true;
  render(<NotchApp />); expect(screen.getByText("Speaking")).toBeTruthy();
  expect(screen.queryByRole("button", { name: "Voice details" })).toBeNull();
  expect(screen.queryByText("Fictional appointment at noon.")).toBeNull();
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
  await userEvent.click(screen.getByRole("button", { name: "Hide review", exact: true }));
  fireEvent.keyDown(window, { key: "Enter" });
  expect(mock.command.mock.calls.some(([c]) => c.action === "approve")).toBe(false);
  await userEvent.click(screen.getByRole("button", { name: "Review", exact: true }));
  fireEvent.keyDown(window, { key: "Enter", repeat: true });
  fireEvent.keyDown(screen.getByRole("button", { name: "Hide review", exact: true }), { key: "Enter" });
  expect(mock.command.mock.calls.some(([c]) => c.action === "approve")).toBe(false);
  fireEvent.keyDown(window, { key: "Enter" });
  expect(mock.command.mock.calls.filter(([c]) => c.action === "approve")).toHaveLength(1);
  mock.state = { ...mock.state, approvalToken: "replacement" }; view.rerender(<NotchApp />);
  fireEvent.keyDown(window, { key: "Enter" });
  expect(mock.command.mock.calls.filter(([c]) => c.action === "approve")).toHaveLength(1);
});
function voiceYearReview() {
  voiceReview();
  mock.state.approvalToken = "review-first"; mock.state.canApprove = false; mock.state.checking = false;
  mock.state.proposals = [{ ...mock.state.proposals[0], isSelected: false, isApprovable: false, canSelect: false, issues: ["Confirm the year.", "Confirm the event duration."] }];
  mock.state.proposals[0].draft = { ...mock.state.proposals[0].draft, ambiguities: ["missingYear", "missingEndTime"] };
}
it("confirms the year of a voice review in the notch with the newest token and never approves it", async () => {
  voiceYearReview(); const view = render(<NotchApp />);
  const field = screen.getByRole("spinbutton", { name: "Year for unconfirmed events" });
  await userEvent.type(field, "2027");
  // A native refresh arrives while the user is typing: the text stays and the new token is the one sent.
  mock.state = { ...mock.state, approvalToken: "review-refreshed" }; view.rerender(<NotchApp />);
  expect((screen.getByRole("spinbutton", { name: "Year for unconfirmed events" }) as HTMLInputElement).value).toBe("2027");
  fireEvent.keyDown(field, { key: "Enter" });
  await userEvent.click(screen.getByRole("button", { name: "Confirm year" }));
  expect(mock.command).toHaveBeenCalledWith({ action: "confirmProposalYears", token: "review-refreshed", year: 2027 });
  expect(document.activeElement).toBe(screen.getByRole("region", { name: "Proposed changes" }));
  expect(mock.command.mock.calls.some(([c]) => ["approve", "stopVoice", "skipApproval"].includes(c.action))).toBe(false);
  // Other unresolved details stay on the row after the year is settled.
  mock.state = { ...mock.state, approvalToken: "review-after-year", proposals: [{ ...mock.state.proposals[0], issues: ["Confirm the event duration."], draft: { ...mock.state.proposals[0].draft, ambiguities: ["missingEndTime"] } }] };
  view.rerender(<NotchApp />);
  expect(screen.getByText("Confirm the event duration.")).toBeTruthy();
  expect(screen.queryByRole("button", { name: "Confirm year" })).toBeNull();
});
it("keeps a rejected year typed and explains it beside the field", async () => {
  voiceYearReview(); render(<NotchApp />);
  mock.command.mockImplementation(async (c: { action: string }) => { if (c.action === "confirmProposalYears") throw new Error("The review changed. Check the latest events before continuing."); });
  await userEvent.type(screen.getByRole("spinbutton", { name: "Year for unconfirmed events" }), "2027");
  await userEvent.click(screen.getByRole("button", { name: "Confirm year" }));
  const error = await screen.findByText("The review changed. Check the latest events before continuing.");
  expect(error.closest(".review-year")).toBeTruthy();
  expect((screen.getByRole("spinbutton", { name: "Year for unconfirmed events" }) as HTMLInputElement).value).toBe("2027");
  mock.command.mockReset(); mock.command.mockResolvedValue(undefined);
});
it("waits for the native duplicate check before a year can be confirmed", async () => {
  voiceYearReview(); mock.state.checking = true; render(<NotchApp />);
  await userEvent.type(screen.getByRole("spinbutton", { name: "Year for unconfirmed events" }), "2027");
  expect((screen.getByRole("button", { name: "Confirm year" }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByText("Checking your calendar for duplicates…")).toBeTruthy();
});
it("Escape in the year field leaves voice and its review alone", async () => {
  voiceYearReview(); render(<NotchApp />);
  const field = screen.getByRole("spinbutton", { name: "Year for unconfirmed events" });
  field.focus(); fireEvent.keyDown(field, { key: "Escape" });
  expect(document.activeElement).not.toBe(field);
  expect(mock.command.mock.calls.some(([c]) => ["stopVoice", "approve", "skipApproval"].includes(c.action))).toBe(false);
});
it("does not let Return approve a review that just replaced the one being edited", async () => {
  voiceReview(); const view = render(<NotchApp />);
  mock.state = { ...mock.state, approvalToken: "year-just-confirmed" }; view.rerender(<NotchApp />);
  fireEvent.keyDown(window, { key: "Enter" });
  expect(mock.command.mock.calls.some(([c]) => c.action === "approve")).toBe(false);
});
it("hides typed follow-ups that voice mode would reject", () => {
  voiceReview(); render(<NotchApp />);
  expect(screen.queryByRole("textbox", { name: "Follow-up message" })).toBeNull();
});
it.each(["update", "delete", "move"] as const)("Return never approves %s", async operation => {
  voiceReview(); mock.state.proposals.forEach(p => { p.operation = operation; }); render(<NotchApp />);
  expect(screen.getByRole("button", { name: "Hide review", exact: true })).toBeTruthy();
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

it("restores an unfinished review after leaving and removes it when the task finishes", async () => {
  voiceReview(); const view = render(<NotchApp />);
  expect(screen.getByRole("button", { name: "Hide review", exact: true })).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "Hide review", exact: true }));
  expect(screen.queryByText("Review changes")).toBeNull();
  fireEvent(window, new Event("calshot:notch-collapsed"));
  expect(screen.getByText("Review changes")).toBeTruthy();
  mock.state = { ...mock.state, waitingApproval: false, canApprove: false,
    proposals: mock.state.proposals.map(p => ({ ...p, isFinished: true, state: "added" })),
    messages: [{ role: "assistant", content: "Saved this fictional event." }], summary: "Saved this fictional event." };
  view.rerender(<NotchApp />);
  expect(screen.queryByText("Review changes")).toBeNull();
  expect(screen.queryByText("Saved this fictional event.")).toBeNull();
  expect(screen.queryByRole("button", { name: /review|conversation/i })).toBeNull();
  await waitFor(() => expect(mock.command).toHaveBeenCalledWith(expect.objectContaining({ action: "notchLayout", detail: false })));
});
it("hides spoken transcripts and keeps focus drawing on the compact voice bar", async () => {
  voiceFixture(); mock.state.voice!.caption = "Private assistant transcript"; mock.state.voice!.userTranscript = "Private spoken request";
  mock.state.streaming = "Private streaming response";
  render(<NotchApp />);
  expect(screen.queryByText("Private assistant transcript")).toBeNull();
  expect(screen.queryByText("Private spoken request")).toBeNull();
  expect(screen.queryByText("Private streaming response")).toBeNull();
  await userEvent.click(screen.getByRole("button", { name: "Draw focus" }));
  expect(mock.command).toHaveBeenCalledWith({ action: "setVoiceDrawing", token: "voice-current", drawing: true });
  await waitFor(() => expect(mock.command).toHaveBeenCalledWith(expect.objectContaining({ action: "notchLayout", detail: false })));
});
it("keeps successful task results compact while preserving partial failure details", () => {
  voiceFixture();
  mock.state.taskOutcome = { id: "result", status: "saved", headline: "Saved task", viaSavedPermission: true, rows: [] };
  const view = render(<NotchApp />);
  expect(screen.queryByLabelText("Task result")).toBeNull();
  mock.state = { ...mock.state, taskOutcome: { ...mock.state.taskOutcome!, status: "partial", headline: "One task needs attention", rows: [{ id: "failed", title: "Fictional task", status: "failed", message: "Could not save" }] } };
  view.rerender(<NotchApp />);
  expect(screen.getByText("Could not save")).toBeTruthy();
});
it("does not revive skipped proposal rows when returning to the notch", () => {
  mock.state.waitingApproval = false; mock.state.canApprove = false;
  mock.state.proposals = mock.state.proposals.map(p => ({ ...p, isSelected: false }));
  render(<NotchApp />); fireEvent(window, new Event("calshot:notch-collapsed"));
  expect(screen.queryByText("Review changes")).toBeNull();
  expect(screen.queryByRole("button", { name: "Review", exact: true })).toBeNull();
});
it("does not offer a completed screenshot for import again", () => {
  mock.state.waitingApproval = false; mock.state.canApprove = false; mock.state.messages = [];
  mock.state.imageURL = "fixture://finished-capture";
  mock.state.proposals = mock.state.proposals.map(p => ({ ...p, isFinished: true, state: "added" }));
  render(<NotchApp />);
  expect(screen.queryByRole("button", { name: "Add to calendar", exact: true })).toBeNull();
  expect(screen.getByRole("button", { name: "Capture" })).toBeTruthy();
});

it("keeps the glowing voice pill in compact mode and requires expansion for review controls", async () => {
 voiceReview(); mock.state.notchExpanded=false; mock.state.voice!.state="waitingForReview";
 render(<NotchApp />);
 expect(screen.getByText("Ready to approve")).toBeTruthy();
 expect(screen.queryByRole("region",{name:"Review calendar changes"})).toBeNull();
 fireEvent.keyDown(window,{key:"Enter"});
 expect(mock.command.mock.calls.some(([c])=>c.action==="approve")).toBe(false);
 await userEvent.click(screen.getByRole("button",{name:"Show task controls"}));
 expect(mock.command).toHaveBeenCalledWith({action:"expandNotch"});
 expect(screen.queryByRole("button",{name:"Voice details"})).toBeNull();
});

it("suspends an unfinished editor behind the compact pill and restores its input", async () => {
 voiceReview(); mock.state.notchExpanded=true; const view=render(<NotchApp />);
 await userEvent.click(screen.getAllByRole("button",{name:"Edit "+mock.state.proposals[0].draft.title})[0]);
 const title=screen.getByRole("textbox",{name:"Event title"});
 await userEvent.clear(title); await userEvent.type(title,"Unfinished fictional title");
 mock.state={...mock.state,notchExpanded:false}; view.rerender(<NotchApp />);
 expect(screen.queryByRole("dialog")).toBeNull();
 expect(screen.getByRole("button",{name:"Show task controls"})).toBeTruthy();
 mock.state={...mock.state,notchExpanded:true}; view.rerender(<NotchApp />);
 expect(screen.getByRole("dialog")).toBeTruthy();
 expect((screen.getByRole("textbox",{name:"Event title"}) as HTMLInputElement).value).toBe("Unfinished fictional title");
});

it("keeps the talk button mounted as a held turn starts listening", () => {
  voiceFixture();
  const view = render(<NotchApp />);
  const button = screen.getByRole("button", { name: "Hold to talk" });
  fireEvent.pointerDown(button, { button: 0, pointerId: 1 });
  mock.state = { ...mock.state, voice: { ...mock.state.voice!, talking: true } };
  view.rerender(<NotchApp />);
  expect(screen.getByRole("button", { name: "Hold to talk" })).toBe(button);
  fireEvent.pointerUp(window, { pointerId: 1 });
  expect(mock.command.mock.calls.filter(([c]) => c.action === "voiceTalk" && !c.pressed)).toHaveLength(1);
});

it("releases an idle microphone press after it becomes a live voice pill", () => {
  voiceFixture(); mock.state.voice!.active = false;
  const view = render(<NotchApp />);
  fireEvent.pointerDown(screen.getByRole("button", { name: "Hold to talk" }), { button: 0, pointerId: 1 });
  mock.state = { ...mock.state, voice: { ...mock.state.voice!, active: true, talking: true } };
  view.rerender(<NotchApp />);
  fireEvent.pointerUp(window, { pointerId: 1 });
  expect(mock.command.mock.calls.filter(([c]) => c.action === "voiceTalk" && !c.pressed)).toHaveLength(1);
});

it("releases a held keyboard turn once when focus leaves the notch", () => {
  voiceFixture(); render(<NotchApp />);
  fireEvent.keyDown(screen.getByRole("button", { name: "Hold to talk" }), { key: " " });
  fireEvent(window, new Event("blur"));
  fireEvent.keyUp(window, { key: " " });
  expect(mock.command.mock.calls.filter(([c]) => c.action === "voiceTalk" && !c.pressed)).toHaveLength(1);
});
