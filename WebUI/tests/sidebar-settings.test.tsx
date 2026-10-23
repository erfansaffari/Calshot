import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SettingsPage } from "../src/views/Pages";
import { preview } from "../src/preview";
import { CalendarPresentationProvider } from "../src/calendarPresentation";
import { Sidebar } from "../src/components/Sidebar";
import type { Page } from "../src/types";
vi.mock("../src/bridge", () => ({
  command: vi.fn().mockResolvedValue(undefined),
}));
afterEach(cleanup);

const widthFor = (page: Page, sidebarWidth?: number) => {
  const view = render(
    <CalendarPresentationProvider>
      <Sidebar
        state={{ ...preview, page, sidebarExpanded: true, sidebarWidth }}
        onAction={async () => {}}
      />
    </CalendarPresentationProvider>,
  );
  const width = view.container.querySelector<HTMLElement>("#workspace-sidebar")!.style.width;
  view.unmount();
  return width;
};

it("keeps one saved sidebar width in every section", () => {
  for (const saved of [undefined, 200, 300]) {
    const widths = (["chat", "calendars", "tasks", "library", "settings"] as Page[]).map(
      (page) => widthFor(page, saved),
    );
    expect(new Set(widths)).toEqual(new Set([`${saved ?? 228}px`]));
  }
});

it("bounds a saved width outside the supported range", () => {
  expect(widthFor("calendars", 900)).toBe("320px");
  expect(widthFor("chat", 40)).toBe("184px");
});

it("keeps the collapsed rail fixed on every section", () => {
  for (const page of ["chat", "calendars", "tasks", "library", "settings"] as Page[]) {
    const view = render(
      <CalendarPresentationProvider>
        <Sidebar state={{ ...preview, page, sidebarExpanded: false, sidebarWidth: 300 }} onAction={async () => {}} />
      </CalendarPresentationProvider>,
    );
    const sidebar = view.container.querySelector<HTMLElement>("#workspace-sidebar")!;
    expect(sidebar.style.width).toBe("");
    expect(sidebar.className).toContain("sidebar-collapsed");
    view.unmount();
  }
});

it("groups appearance and capture preferences with every control kept", async () => {
  render(<SettingsPage state={preview} />);
  expect(screen.getByRole("heading", { name: "Appearance & capture" })).toBeTruthy();
  expect(screen.getByRole("combobox", { name: "Appearance" })).toBeTruthy();
  expect(screen.getByRole("checkbox", { name: "Copy captures to clipboard" })).toBeTruthy();
  expect(screen.getByRole("button", { name: preview.shortcut })).toBeTruthy();
});

it("keeps billing and privacy explanations on their settings sections", async () => {
  render(<SettingsPage state={preview} />);
  await userEvent.click(screen.getByRole("button", { name: "AI service" }));
  expect(screen.getByText(/billed by OpenAI, separately from ChatGPT/)).toBeTruthy();
  expect(screen.getByText(/separate from AI billing/)).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "Privacy & permissions" }));
  expect(screen.getByText(/OpenAI processes them under its own policies/)).toBeTruthy();
  expect(screen.getByText(/Removing history never changes calendar events/)).toBeTruthy();
});
