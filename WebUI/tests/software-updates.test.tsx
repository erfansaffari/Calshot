import { cleanup, render, screen, fireEvent, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SoftwareUpdates } from "../src/views/SoftwareUpdates";
import { preview } from "../src/preview";
afterEach(cleanup);
const update = { version: "1.0.0", build: "1", available: true, canCheck: true, checking: false, status: "You’re up to date.", automaticChecks: true, automaticDownloads: true, development: false };
describe("Software updates", () => {
  it("uses native preferences and shows an actionable failure beside the controls", async () => {
    const onAction = vi.fn().mockRejectedValue(new Error("Try again when the check finishes."));
    render(<SoftwareUpdates state={{ ...preview, native: true, softwareUpdate: update }} onAction={onAction} />);
    fireEvent.click(screen.getByRole("checkbox", { name: "Download updates automatically" }));
    await waitFor(() => expect(onAction).toHaveBeenCalledWith("updatePreferences", { checks: true, downloads: false }));
    expect(await screen.findByText("Try again when the check finishes.")).toBeTruthy();
    expect((screen.getByRole("checkbox", { name: "Download updates automatically" }) as HTMLInputElement).checked).toBe(true);
  });
  it("hides Mac update controls on the website", () => {
    render(<SoftwareUpdates state={{ ...preview, native: false, softwareUpdate: update }} onAction={vi.fn()} />);
    expect(screen.queryByText("Software updates")).toBeNull();
  });
});
