import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SettingsPage } from "../src/views/Pages";
import { preview } from "../src/preview";
import { command } from "../src/bridge";
vi.mock("../src/bridge", () => ({ command: vi.fn().mockResolvedValue(undefined) }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
it("saves device voice settings with native token and leaves text billing alone", async () => {
  render(<SettingsPage state={{ ...preview, settingsSection: "voice", voice: { token: "fixture", state: "idle", active: false, inputLevel: 0, caption: "", userTranscript: "", drawing: false, usage: { seconds: 0, estimatedCost: 0 }, needsKey: false, needsAcknowledgement: false, permissions: { microphone: false, screen: false }, model: "fictional-realtime", voice: "marin", monthlyCap: 10 } }} />);
  expect(screen.getByText(/ChatGPT plan billing does not cover voice/)).toBeTruthy();
  await userEvent.click(screen.getByText("Save voice settings"));
  expect(command).toHaveBeenCalledWith({ action: "voiceSettings", token: "fixture", model: "fictional-realtime", voice: "marin", cap: 10 });
  expect(vi.mocked(command).mock.calls.some(([c]) => c.action === "provider")).toBe(false);
});
