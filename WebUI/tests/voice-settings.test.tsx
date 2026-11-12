import { afterEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SettingsPage } from "../src/views/Pages";
import { Sidebar } from "../src/components/Sidebar";
import { preview } from "../src/preview";
import { command } from "../src/bridge";
vi.mock("../src/bridge", () => ({ command: vi.fn().mockResolvedValue(undefined) }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
it("saves device voice settings with the current native token and discloses audio and screen sharing", async () => {
  render(<SettingsPage state={{ ...preview, settingsSection: "voice", voice: { token: "fixture", state: "idle", active: false, inputLevel: 0, caption: "", userTranscript: "", drawing: false, usage: { seconds: 0, estimatedCost: 0 }, needsKey: false, needsAcknowledgement: false, permissions: { microphone: false, screen: false }, model: "fictional-realtime", voice: "marin", monthlyCap: 10 } }} />);
  expect(screen.getByText(/ChatGPT plan billing does not cover voice/)).toBeTruthy();
  await userEvent.click(screen.getByText("Save voice settings"));
  expect(command).toHaveBeenCalledWith({ action: "voiceSettings", token: "fixture", model: "fictional-realtime", voice: "marin", cap: 10 });
  expect(screen.getByText(/Microphone audio and screen frames are sent to OpenAI/)).toBeTruthy();
});
const voice = { token: "fixture", state: "idle", active: false, inputLevel: 0, caption: "", userTranscript: "", drawing: false, usage: { seconds: 0, estimatedCost: 0 }, needsKey: false, needsAcknowledgement: false, permissions: { microphone: true, screen: true }, model: "fictional-realtime", voice: "marin", monthlyCap: 10 };
const shortcuts = (patch = {}) => ({ recording: null, capture: { label: "⌃⇧C", isDefault: true }, voice: { label: "⌃⇧V", isDefault: true }, ...patch });
it("starts native listening for the capture shortcut with the current token", async () => {
  render(<SettingsPage state={{ ...preview, voice, shortcuts: shortcuts() }} />);
  await userEvent.click(screen.getByRole("button", { name: "⌃⇧C" }));
  expect(command).toHaveBeenCalledWith({ action: "shortcutRecording", token: "fixture", target: "capture", enabled: true });
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({ action: "advancedSettings" }));
});
it("leaves the key press to native code: WebKit doesn't focus a clicked button, so JavaScript can't rely on seeing it", async () => {
  render(<SettingsPage state={{ ...preview, settingsSection: "voice", voice, shortcuts: shortcuts({ recording: "voice" }) }} />);
  expect(screen.getByRole("button", { name: "Press shortcut…" }).getAttribute("aria-pressed")).toBe("true");
  fireEvent.keyDown(screen.getByRole("button", { name: "Press shortcut…" }), { key: "x", code: "KeyX", ctrlKey: true, shiftKey: true });
  fireEvent.keyDown(window, { key: "x", code: "KeyX", ctrlKey: true, shiftKey: true });
  expect(command).not.toHaveBeenCalled();
  await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
  expect(command).toHaveBeenCalledWith({ action: "shortcutRecording", token: "fixture", target: "voice", enabled: false });
});
it("ends listening when the control goes away, so the global shortcuts come back", () => {
  const view = render(<SettingsPage state={{ ...preview, settingsSection: "voice", voice, shortcuts: shortcuts({ recording: "voice" }) }} />);
  view.unmount();
  expect(command).toHaveBeenCalledWith({ action: "shortcutRecording", token: "fixture", target: "voice", enabled: false });
});
it("keeps a shortcut conflict beside the control with the shortcut still in use", () => {
  const error = "Another app is using ⌃⇧X (error -9878). Still using ⌃⇧V.";
  render(<SettingsPage state={{ ...preview, settingsSection: "voice", voice, shortcuts: shortcuts({ voice: { label: "⌃⇧V", isDefault: true, error } }) }} />);
  expect(screen.getByRole("button", { name: "⌃⇧V" })).toBeTruthy();
  expect(screen.getByText(error)).toBeTruthy();
});
it("offers Reset only for a changed shortcut and blocks changes during voice", async () => {
  const view = render(<SettingsPage state={{ ...preview, voice, shortcuts: shortcuts({ capture: { label: "⌃⌥P", isDefault: false } }) }} />);
  await userEvent.click(screen.getByRole("button", { name: "Reset" }));
  expect(command).toHaveBeenCalledWith({ action: "resetShortcut", token: "fixture", target: "capture" });
  view.rerender(<SettingsPage state={{ ...preview, voice: { ...voice, active: true }, shortcuts: shortcuts() }} />);
  expect((screen.getByRole("button", { name: "⌃⇧C" }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getAllByText("Stop voice to change this.").length).toBeGreaterThan(0);
});
it("doesn't advertise a capture shortcut macOS isn't running", () => {
  render(<Sidebar state={{ ...preview, shortcuts: shortcuts({ capture: { label: "⌃⇧C", isDefault: true, error: "⌃⇧C isn’t working." } }) }} onAction={async () => {}} />);
  expect(screen.getByText("Shortcut off")).toBeTruthy();
});

it("offers Sound settings for device failures even when microphone permission is allowed", async () => {
  render(<SettingsPage state={{ ...preview, settingsSection: "voice", voice: { ...voice, state: "failed", audioIssue: "devices", error: "macOS hasn’t provided a usable microphone. Check Sound → Input." } }} />);
  expect(screen.getByRole("alert").textContent).toContain("usable microphone");
  await userEvent.click(screen.getByRole("button", { name: "Open Sound settings" }));
  expect(command).toHaveBeenCalledWith({ action: "voiceInputSettings", token: "fixture" });
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({ action: "startVoice" }));
  await userEvent.click(screen.getByRole("button", { name: "Retry voice" }));
  expect(command).toHaveBeenCalledWith({ action: "startVoice", token: "fixture" });
});
