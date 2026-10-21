import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { CalendarConnections } from "../src/views/Pages";
import { preview } from "../src/preview";
import type { AppState } from "../src/types";
vi.mock("../src/bridge", () => ({
  command: vi.fn().mockResolvedValue(undefined),
}));
import { command } from "../src/bridge";
afterEach(() => {
  cleanup();
  vi.mocked(command).mockClear();
});
function fixture(): AppState {
  return {
    ...preview,
    running: false,
    saving: false,
    calendars: [
      {
        id: "fictional-calendar",
        title: "School",
        sourceName: "iCloud",
        provider: "apple",
        isReadOnly: true,
        direct: false,
        unavailable: false,
      },
    ],
    auth: {
      required: true,
      signedIn: true,
      onboarded: true,
      phase: "signedIn",
      busy: false,
      googleEnabled: true,
    },
    webCalendarSync: {
      busy: false,
      sourceKeys: { "fictional-calendar": "opaque" },
      mirrors: [],
    },
  };
}
it("requires an explicit per-calendar choice and supports read-only sources", async () => {
  render(<CalendarConnections state={fixture()} />);
  expect(command).not.toHaveBeenCalled();
  expect(
    screen.getByText(/event titles, times and locations privately/),
  ).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "Sync to web" }));
  expect(command).toHaveBeenCalledWith({
    action: "setMacCalendarSync",
    calendarID: "fictional-calendar",
    enabled: true,
  });
});
it("keeps calendar sync errors visible and supports stopping", async () => {
  const state = fixture();
  state.webCalendarSync!.mirrors = [
    {
      id: "mirror",
      sourceKey: "opaque",
      generation: "version",
      enabled: true,
      name: "School",
      complete: false,
      error: "Calendar access was lost.",
    },
  ];
  render(<CalendarConnections state={state} />);
  expect(screen.getByRole("alert").textContent).toContain(
    "Calendar access was lost.",
  );
  await userEvent.click(screen.getByRole("button", { name: "Stop syncing" }));
  expect(command).toHaveBeenCalledWith({
    action: "setMacCalendarSync",
    calendarID: "fictional-calendar",
    enabled: false,
  });
});
it("disables repeated choices while a snapshot is syncing", () => {
  const state = fixture();
  state.webCalendarSync!.busy = true;
  render(<CalendarConnections state={state} />);
  expect(
    (screen.getByRole("button", { name: "Sync to web" }) as HTMLButtonElement)
      .disabled,
  ).toBe(true);
});
