import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { PersonalMemorySettings } from "../src/views/Pages";
import { preview } from "../src/preview";
import type { PersonalMemoryItem } from "../src/types";
import { command } from "../src/bridge";
vi.mock("../src/bridge", () => ({
  command: vi.fn().mockResolvedValue(undefined),
}));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});
const item: PersonalMemoryItem = {
  id: "fictional-item",
  version: "v1",
  kind: "preference",
  text: "Quiet mornings",
  origin: "explicit",
  status: "active",
  createdAt: "2026-10-29",
  updatedAt: "2026-10-29",
};
const state = (
  items: PersonalMemoryItem[] = [],
  pending: PersonalMemoryItem[] = [],
) => ({
  ...preview,
  personalMemory: { loaded: true, items, pending, token: "current" },
});
it("shows empty and adds an explicit memory with native token", async () => {
  render(<PersonalMemorySettings state={state()} />);
  expect(screen.getByText("No personal memories yet.")).toBeTruthy();
  await userEvent.type(screen.getByLabelText("New memory"), "Quiet mornings");
  await userEvent.click(screen.getByRole("button", { name: "Add memory" }));
  expect(command).toHaveBeenCalledWith({
    action: "addMemory",
    token: "current",
    kind: "preference",
    text: "Quiet mornings",
  });
});
it("lists, edits and forgets using current versions", async () => {
  render(<PersonalMemorySettings state={state([item])} />);
  expect(screen.getByText("Quiet mornings")).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "Edit" }));
  await userEvent.clear(screen.getByLabelText("Memory text"));
  await userEvent.type(screen.getByLabelText("Memory text"), "Quiet evenings");
  await userEvent.click(screen.getByRole("button", { name: "Save memory" }));
  expect(command).toHaveBeenCalledWith({
    action: "editMemory",
    token: "current",
    memoryID: item.id,
    expectedVersion: "v1",
    kind: "preference",
    text: "Quiet evenings",
  });
  await userEvent.click(
    screen.getByRole("button", { name: "Forget", exact: true }),
  );
  expect(command).toHaveBeenCalledWith({
    action: "forgetMemory",
    token: "current",
    memoryID: item.id,
    expectedVersion: "v1",
  });
});
it("approves or rejects suggestions and supports suppression", async () => {
  render(
    <PersonalMemorySettings
      state={state(
        [],
        [{ ...item, status: "pendingApproval", origin: "suggested" }],
      )}
    />,
  );
  await userEvent.click(
    screen.getByRole("button", { name: "Approve", exact: true }),
  );
  expect(command).toHaveBeenLastCalledWith({
    action: "approveMemory",
    token: "current",
    memoryID: item.id,
    expectedVersion: "v1",
  });
  await userEvent.click(
    screen.getByRole("button", { name: "Reject", exact: true }),
  );
  expect(command).toHaveBeenLastCalledWith(
    expect.objectContaining({
      action: "rejectMemory",
      dontSuggestAgain: false,
    }),
  );
  await userEvent.click(
    screen.getByRole("button", { name: "Don't suggest again" }),
  );
  expect(command).toHaveBeenLastCalledWith(
    expect.objectContaining({ action: "rejectMemory", dontSuggestAgain: true }),
  );
});
it("keeps errors beside affected memory", async () => {
  vi.mocked(command).mockRejectedValueOnce(
    new Error("Memory changed. Review it again."),
  );
  render(<PersonalMemorySettings state={state([item])} />);
  await userEvent.click(
    screen.getByRole("button", { name: "Forget", exact: true }),
  );
  expect(screen.getByRole("alert").textContent).toContain("Memory changed");
});
it("shows loading and persistent storage errors", () => {
  const view = render(
    <PersonalMemorySettings
      state={{
        ...state(),
        personalMemory: { ...state().personalMemory, loaded: false },
      }}
    />,
  );
  expect(screen.getByText("Loading memories…")).toBeTruthy();
  view.rerender(
    <PersonalMemorySettings
      state={{
        ...state(),
        personalMemory: {
          ...state().personalMemory,
          loaded: false,
          error: "File kept unchanged",
        },
      }}
    />,
  );
  expect(screen.getByRole("alert").textContent).toContain(
    "File kept unchanged",
  );
  expect(
    screen.getByRole<HTMLButtonElement>("button", { name: "Add memory" })
      .disabled,
  ).toBe(true);
});
