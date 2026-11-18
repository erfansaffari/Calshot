import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SettingsPage } from "../src/views/Pages";
import { Review } from "../src/components/Review";
import { preview } from "../src/preview";
import { command } from "../src/bridge";
import { alertLeadLabel, alertSummary } from "../src/alertPresentation";
import type { NotificationsState } from "../src/types";
vi.mock("../src/bridge", () => ({ command: vi.fn().mockResolvedValue(undefined) }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });

const base: NotificationsState = { enabled: true, sound: true, spoken: false, smartAlerts: true, systemPermission: "allowed", voiceReady: true, error: null, lastRefresh: new Date().toISOString(), upcoming: [] };
const settings = (patch: Partial<NotificationsState> = {}) => ({ ...preview, settingsSection: "notifications" as const, notifications: { ...base, ...patch } });

it("sends each device-local choice as one boolean, with spoken alerts off by default", async () => {
  render(<SettingsPage state={settings()} />);
  const spoken = screen.getByRole("switch", { name: "Say alerts out loud" });
  expect(spoken.getAttribute("aria-checked")).toBe("false");
  await userEvent.click(spoken);
  expect(command).toHaveBeenCalledWith({ action: "notificationPreferences", spoken: true });
  await userEvent.click(screen.getByRole("switch", { name: "Let Calshot choose alerts" }));
  expect(command).toHaveBeenCalledWith({ action: "notificationPreferences", smartAlerts: false });
  await userEvent.click(screen.getByRole("button", { name: "Preview" }));
  expect(command).toHaveBeenCalledWith({ action: "previewAlert" });
});

it("explains what syncs, disables dependent choices when alerts are off, and shows the empty day", () => {
  render(<SettingsPage state={settings({ enabled: false })} />);
  expect(screen.getByText(/saved on the event in your calendar account/)).toBeTruthy();
  expect((screen.getByRole("switch", { name: "Alert sound" }) as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByRole("switch", { name: "Say alerts out loud" }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByText("Calshot alerts are off.")).toBeTruthy();
});

it("keeps read errors and missing permission beside the affected section with a way forward", async () => {
  render(<SettingsPage state={settings({ systemPermission: "denied", error: "Couldn’t read Fictional Work. Alerts from it may be missing until it reconnects.", spoken: true, voiceReady: false })} />);
  expect(screen.getByText(/Couldn’t read Fictional Work/)).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "Try again" }));
  expect(command).toHaveBeenCalledWith({ action: "refreshAlerts" });
  await userEvent.click(screen.getByRole("button", { name: "Open System Settings" }));
  expect(command).toHaveBeenCalledWith({ action: "notificationSystemSettings" });
  expect(screen.getByText(/Voice isn’t ready yet/)).toBeTruthy();
});

it("lists upcoming alerts with their lead time, meeting link and long titles", () => {
  const at = (m: number) => new Date(Date.now() + m * 60000).toISOString();
  render(<SettingsPage state={settings({ upcoming: [
    { id: "1", kind: "event", title: "Fictional design review", start: at(40), fireAt: at(30), lead: 10, calendarName: "Work", snoozed: false, join: true },
    { id: "2", kind: "task", title: "Fictional lab report", start: at(120), fireAt: at(60), lead: 60, calendarName: null, snoozed: false, join: false },
  ] })} />);
  const list = screen.getByRole("list", { name: "Upcoming alerts" });
  expect(within(list).getByText(/10 min before .* Meeting link/)).toBeTruthy();
  expect(within(list).getByText(/1 hour before · Task/)).toBeTruthy();
});

it("labels alerts like native code", () => {
  expect(alertLeadLabel(0)).toBe("At start");
  expect(alertLeadLabel(0, "task")).toBe("At due time");
  expect(alertLeadLabel(1440)).toBe("1 day before");
  expect(alertLeadLabel(90)).toBe("1 h 30 min before");
  expect(alertSummary(null)).toBe("Calendar default");
  expect(alertSummary([])).toBe("None");
  expect(alertSummary([10, 60])).toBe("10 min before, 1 hour before");
});

it("shows an alert change on its review row", () => {
  const draft = { id: "d", title: "Fictional standup", startDate: "2027-01-15T14:00:00Z", endDate: "2027-01-15T14:15:00Z", isAllDay: false, sourceText: "", ambiguities: [] };
  const proposal = { id: "p", operation: "update" as const, state: "ready", draft: { ...draft, alertMinutes: [5], changedFieldNames: ["alerts"] }, before: { ...draft, alertMinutes: [10] },
    isSelected: true, isFinished: false, isApprovable: true, canSelect: true, inScope: true, status: "Ready", issues: [], duplicateIdentifiers: [], allowDuplicate: false };
  render(<Review state={{ ...preview, proposals: [proposal], waitingApproval: true, canApprove: true }} />);
  expect(screen.getByText("Alerts: 10 min before → 5 min before")).toBeTruthy();
});
