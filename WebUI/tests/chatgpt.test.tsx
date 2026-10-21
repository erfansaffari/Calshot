import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SettingsPage } from "../src/views/Pages";
import { preview } from "../src/preview";
vi.mock("../src/bridge", () => ({
  command: vi.fn().mockResolvedValue(undefined),
}));
import { command } from "../src/bridge";
afterEach(() => {
  cleanup();
  vi.mocked(command).mockClear();
});
it("offers reconnect after expired plan permission without changing the billing route", async () => {
  render(
    <SettingsPage
      state={{
        ...preview,
        settingsSection: "ai",
        settings: {
          ...preview.settings,
          chatGPTEmail: "alex@example.invalid",
          chatGPTPlan: false,
          chatGPTError: "Session expired. Reconnect.",
          useAPIKey: true,
        },
      }}
    />,
  );
  expect(screen.getByText(/Saved account:/)).toBeTruthy();
  expect(screen.queryByRole("button", { name: "Test ChatGPT" })).toBeNull();
  await userEvent.click(screen.getByRole("button", { name: "Reconnect" }));
  expect(command).toHaveBeenCalledWith({ action: "connectChatGPT" });
  expect(
    vi.mocked(command).mock.calls.some(([c]) => c.action === "provider"),
  ).toBe(false);
});
it("shows cancellable browser progress without offering a second connection", async () => {
  render(
    <SettingsPage
      state={{
        ...preview,
        settingsSection: "ai",
        settings: { ...preview.settings, chatGPTConnecting: true },
      }}
    />,
  );
  expect(screen.getByRole("status").textContent).toContain(
    "Finish ChatGPT sign-in",
  );
  expect(screen.queryByRole("button", { name: "Reconnect" })).toBeNull();
  await userEvent.click(
    screen.getByRole("button", { name: "Cancel", exact: true }),
  );
  expect(command).toHaveBeenCalledWith({ action: "cancelChatGPT" });
});
it("tests the chosen ChatGPT grant explicitly", async () => {
  render(
    <SettingsPage
      state={{
        ...preview,
        settingsSection: "ai",
        settings: { ...preview.settings, chatGPTPlan: true },
      }}
    />,
  );
  await userEvent.click(screen.getByRole("button", { name: "Test ChatGPT" }));
  expect(command).toHaveBeenCalledWith({ action: "testChatGPT" });
});
