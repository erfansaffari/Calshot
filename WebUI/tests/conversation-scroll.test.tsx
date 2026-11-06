import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { preview } from "../src/preview";
import type { AppState } from "../src/types";
import { CalendarPresentationProvider } from "../src/calendarPresentation";
const mock = vi.hoisted(() => ({ state: {} as AppState }));
vi.mock("../src/bridge", () => ({ useAppState: () => mock.state, command: vi.fn().mockResolvedValue(undefined) }));
import App from "../src/App";
const originalHeight = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "scrollHeight");
beforeEach(() => {
  mock.state = { ...structuredClone(preview), page: "chat", proposals: [], waitingApproval: false,
    messages: Array.from({ length: 30 }, (_, i) => ({ role: "user", content: `Fictional message ${i}` })) };
  Object.defineProperty(HTMLElement.prototype, "scrollHeight", { configurable: true, get() { return this.classList.contains("timeline") ? 2000 : 40; } });
});
afterEach(() => {
  cleanup();
  if (originalHeight) Object.defineProperty(HTMLElement.prototype, "scrollHeight", originalHeight);
  else delete (HTMLElement.prototype as Partial<HTMLElement>).scrollHeight;
});
const workspace = () => <CalendarPresentationProvider><App /></CalendarPresentationProvider>;
it("opens at the newest message on every return to Assistant, even after reading old messages", async () => {
  const view = render(workspace());
  const first = view.container.querySelector<HTMLElement>(".timeline")!;
  await waitFor(() => expect(first.scrollTop).toBe(2000));
  first.scrollTop = 100; fireEvent.scroll(first);
  mock.state = { ...mock.state, page: "settings" }; view.rerender(workspace());
  mock.state = { ...mock.state, page: "chat" }; view.rerender(workspace());
  expect(view.container.querySelector<HTMLElement>(".timeline")!.scrollTop).toBe(2000);
});
it("does not pull someone away from older messages while the chat remains open", async () => {
  const view = render(workspace());
  const timeline = view.container.querySelector<HTMLElement>(".timeline")!;
  await waitFor(() => expect(timeline.scrollTop).toBe(2000));
  timeline.scrollTop = 100; fireEvent.scroll(timeline);
  mock.state = { ...mock.state, messages: [...mock.state.messages, { role: "assistant", content: "Fictional new reply" }] };
  view.rerender(workspace());
  expect(timeline.scrollTop).toBe(100);
});
