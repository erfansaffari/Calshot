import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SettingsPage } from "../src/views/Pages";
import { preview } from "../src/preview";
import type { AppState } from "../src/types";
vi.mock("../src/bridge", () => ({ command: vi.fn().mockResolvedValue(undefined) }));
import { command } from "../src/bridge";
afterEach(() => { cleanup(); vi.mocked(command).mockClear(); });
function state(): AppState {
  return { ...preview, settingsSection: "general", auth: { required: true, signedIn: true, onboarded: true, phase: "signedIn", busy: false, googleEnabled: true, email: "alex@example.invalid" }, accountSync: { busy: false, status: "Up to date", displayName: "Alex", deviceID: "local", devices: { remote: { name: "Fictional laptop", updatedAt: "2026-10-19T00:00:00Z", connections: [{ key: "fictional-google", provider: "google", label: "alex@example.invalid" }] } } } };
}
it("distinguishes saved accounts from authorization on this Mac and offers sync", async () => {
  render(<SettingsPage state={state()} />);
  expect(screen.getByText("Reconnect on this Mac to use this account")).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "Sync now" }));
  expect(command).toHaveBeenCalledWith({ action: "syncAccount" });
  await userEvent.click(screen.getByRole("button", { name: "Manage connection" }));
  expect(command).toHaveBeenCalledWith({ action: "navigate", page: "settings", section: "calendars" });
});
it("keeps sync errors visible and disables repeated requests while syncing", () => {
  const value = state(); value.accountSync = { ...value.accountSync!, busy: true, error: "Offline. Local changes are kept." };
  render(<SettingsPage state={value} />);
  expect(screen.getByRole("alert").textContent).toContain("Offline. Local changes are kept.");
  expect((screen.getByRole("button", { name: "Sync now" }) as HTMLButtonElement).disabled).toBe(true);
});
it("hides sync details when signed out", () => {
  const value = state(); value.auth!.signedIn = false;
  render(<SettingsPage state={value} />);
  expect(screen.queryByRole("region", { name: "Account sync" })).toBeNull();
});
