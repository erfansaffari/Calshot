import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen, fireEvent } from "@testing-library/react";
import { AIContextInspector } from "../src/views/Pages";
import { preview } from "../src/preview";
import { command } from "../src/bridge";
vi.mock("../src/bridge", () => ({ command: vi.fn().mockResolvedValue(undefined) }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
it("loads context only on request and keeps native excerpts selectable", async () => {
  const view = render(<AIContextInspector state={{ ...preview, native: true }} />);
  expect(command).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "View context" }));
  await vi.waitFor(() => expect(command).toHaveBeenCalledWith({ action: "inspectAIContext" }));
  view.rerender(<AIContextInspector state={{ ...preview, native: true, aiContextInspection: { capturedAt: "2026-11-06T12:00:00Z", sections: [{ title: "Retained conversation", detail: "Bounded excerpts", text: "You: Fictional Aurora plan" }] } }} />);
  expect(screen.getByText(/not the complete prompt/)).toBeTruthy();
  fireEvent.click(screen.getByText("Retained conversation"));
  expect(screen.getByLabelText("Retained conversation contents").textContent).toContain("Fictional Aurora plan");
  fireEvent.click(screen.getByRole("button", { name: "Hide context" }));
  await vi.waitFor(() => expect(command).toHaveBeenCalledWith({ action: "closeAIContext" }));
});
it("keeps failures beside the viewer and allows retry", async () => {
  vi.mocked(command).mockRejectedValueOnce(new Error("Fictional history unavailable"));
  render(<AIContextInspector state={{ ...preview, native: true }} />);
  fireEvent.click(screen.getByRole("button", { name: "View context" }));
  expect(await screen.findByText("Fictional history unavailable")).toBeTruthy();
  expect(screen.getByRole("button", { name: "View context" }).hasAttribute("disabled")).toBe(false);
});
it("does not offer unsupported local inspection on the website", () => {
  render(<AIContextInspector state={{ ...preview, native: false }} />);
  expect(screen.getByRole("button", { name: "View context" }).hasAttribute("disabled")).toBe(true);
});
