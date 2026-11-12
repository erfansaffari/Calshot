import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { RecentChanges, describeChange } from "../src/components/RecentChanges";
import { memorySourceLabel } from "../src/views/Pages";
import type { PersonalMemoryItem, RecentChange, RecentChangesState } from "../src/types";
import { command } from "../src/bridge";
vi.mock("../src/bridge", () => ({ command: vi.fn().mockResolvedValue(undefined), useAppState: vi.fn() }));
const now = Date.parse("2026-11-12T15:00:00Z");
const change = (id: string, extra: Partial<RecentChange> = {}): RecentChange => ({
  id, operation: "create", title: `Fictional event ${id}`, calendar: "Personal", start: "2026-11-14T20:00:00Z", end: null, allDay: false,
  savedAt: new Date(now - 60000).toISOString(), isUndo: false, undone: false, canUndo: true, undoing: false, error: null, ...extra });
const state = (items: RecentChange[]): RecentChangesState => ({ items, token: "changes-token" });
beforeEach(() => { vi.mocked(command).mockReset().mockResolvedValue(undefined); });
afterEach(cleanup);

it("renders nothing without saved changes and filters by time", () => {
  const { container, rerender } = render(<RecentChanges changes={state([])} />);
  expect(container.innerHTML).toBe("");
  rerender(<RecentChanges changes={state([change("old", { savedAt: new Date(now - 3600000).toISOString() })])} since={now - 600000} />);
  expect(container.innerHTML).toBe("");
});

it("undoes one change with the current token and shows its own error next to that row", async () => {
  vi.mocked(command).mockRejectedValueOnce(new Error("That event is no longer in Personal, so there is nothing to undo."));
  render(<RecentChanges changes={state([change("a"), change("b", { operation: "delete" })])} />);
  fireEvent.click(screen.getByRole("button", { name: "Undo added Fictional event a" }));
  expect(command).toHaveBeenCalledWith({ action: "undoChange", changeID: "a", token: "changes-token" });
  expect((await screen.findByRole("alert")).textContent).toContain("nothing to undo");
  expect((screen.getByRole("button", { name: "Undo removed Fictional event b" }) as HTMLButtonElement).disabled).toBe(false);
});

it("shows undone and undo rows without an Undo button", () => {
  render(<RecentChanges changes={state([change("a", { undone: true, canUndo: false }), change("b", { isUndo: true, canUndo: false, operation: "delete" })])} />);
  expect(screen.queryByRole("button")).toBeNull();
  expect(screen.getByText("Undone")).toBeTruthy();
  expect(screen.getByText("Undid: Fictional event b")).toBeTruthy();
});

it("describes moves and renamed events", () => {
  expect(describeChange(change("m", { operation: "move", calendar: "Work", fromCalendar: "Home" }))).toBe("Fictional event m → Work");
  expect(describeChange(change("u", { operation: "update", previousTitle: "Fictional old" }))).toBe("Fictional old → Fictional event u");
});

it("labels where each memory came from", () => {
  const item = (extra: Partial<PersonalMemoryItem>): PersonalMemoryItem => ({ id: "x", version: "v", kind: "fact", text: "Fictional", origin: "learned", status: "active", createdAt: "", updatedAt: "", ...extra });
  expect(memorySourceLabel(item({ source: "behavior" }))).toBe("Learned from how you use Calshot");
  expect(memorySourceLabel(item({ source: "conversation", confidence: 0.5 }))).toBe("Guessed from your conversations");
  expect(memorySourceLabel(item({ source: "user", evidenceCount: 3 }))).toBe("You said this (3 times)");
  expect(memorySourceLabel(item({ origin: "explicit" }))).toBe("You added this");
});
