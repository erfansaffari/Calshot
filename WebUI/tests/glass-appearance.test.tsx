import { afterEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { GlassAppearanceSettings } from "../src/components/GlassAppearanceSettings";
import { useGlassAppearance, defaultGlass } from "../src/appearance";
import { preview } from "../src/preview";
import type { AppState } from "../src/types";
vi.mock("../src/bridge", () => ({ command: vi.fn().mockResolvedValue(undefined) }));
import { command } from "../src/bridge";
afterEach(() => { cleanup(); vi.mocked(command).mockClear(); });
it("recognizes a saved native snapshot regardless of JSON property order", async () => {
  const view = render(<GlassAppearanceSettings state={preview} />);
  fireEvent.change(screen.getByRole("slider", { name: "Window opacity" }), { target: { value: "80" } });
  view.rerender(<GlassAppearanceSettings state={{ ...preview, settings: { ...preview.settings, glass: { contrast: .5, blur: 24, opacity: .8, enabled: true } } }} />);
  await waitFor(() => expect((screen.getByRole("button", { name: "Apply appearance" }) as HTMLButtonElement).disabled).toBe(true));
  expect(screen.queryByText("Preview · changes not applied")).toBeNull();
});
it("keeps material changes as a draft until explicitly applied through the native callback", async () => {
  render(<GlassAppearanceSettings state={preview} />);
  fireEvent.change(screen.getByRole("slider", { name: "Window opacity" }), { target: { value: "80" } });
  fireEvent.change(screen.getByRole("slider", { name: "Surface blur" }), { target: { value: "32" } });
  expect(command).not.toHaveBeenCalled();
  await userEvent.click(screen.getByRole("button", { name: "Apply appearance" }));
  expect(command).toHaveBeenCalledWith({ action: "glassAppearance", enabled: true, opacity: .8, blur: 32, contrast: .5 });
});
it("keeps a failed draft and its actionable error beside the appearance controls", async () => {
  vi.mocked(command).mockRejectedValueOnce(new Error("Appearance couldn’t be saved. Try again."));
  render(<GlassAppearanceSettings state={preview} />);
  fireEvent.change(screen.getByRole("slider", { name: "Surface contrast" }), { target: { value: "75" } });
  await userEvent.click(screen.getByRole("button", { name: "Apply appearance" }));
  expect(await screen.findByRole("alert")).toHaveProperty("textContent", "Appearance couldn’t be saved. Try again.");
  expect((screen.getByRole("slider", { name: "Surface contrast" }) as HTMLInputElement).value).toBe("75");
});
it("can turn glass off while keeping the chosen values for later", async () => {
  render(<GlassAppearanceSettings state={preview} />);
  await userEvent.click(screen.getByRole("switch", { name: "Liquid Glass appearance" }));
  expect((screen.getByRole("slider", { name: "Window opacity" }) as HTMLInputElement).disabled).toBe(true);
  await userEvent.click(screen.getByRole("button", { name: "Apply appearance" }));
  expect(command).toHaveBeenCalledWith({ action: "glassAppearance", ...defaultGlass, enabled: false });
});
function Surface({ state }: { state: AppState }) { useGlassAppearance(state); return <div />; }
it("applies native snapshots to both surfaces and exposes macOS accessibility overrides", async () => {
  const state = { ...preview, settings: { ...preview.settings, glass: { ...defaultGlass, opacity: .8 } }, displayAccessibility: { reducedTransparency: true, increasedContrast: true } };
  const view = render(<Surface state={state} />);
  await waitFor(() => expect(document.documentElement.style.getPropertyValue("--glass-opacity")).toBe("0.8"));
  expect(document.documentElement.dataset.reducedTransparency).toBe("true");
  view.rerender(<Surface state={{ ...state, settings: { ...state.settings, glass: { ...state.settings.glass, enabled: false } } }} />);
  expect(document.documentElement.dataset.glass).toBe("off");
});
