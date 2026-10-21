import { afterEach, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { CalendarPresentationProvider } from "../src/calendarPresentation";
import { CalendarPage } from "../src/views/CalendarPage";
import { FriendsSettings } from "../src/views/FriendsSettings";
import { preview } from "../src/preview";
import {
  friendCalendars,
  type AppState,
  type CalendarShare,
} from "../src/types";
afterEach(cleanup);
const grant: CalendarShare = {
  id: "request",
  ownerID: "riley",
  recipientID: "sam",
  outgoing: false,
  personName: "Riley Example",
  email: "riley@example.invalid",
  permission: "titles",
  status: "pending",
  expiresAt: "2026-10-28T00:00:00Z",
  calendars: [
    {
      id: "studio",
      name: "Studio calendar — design workshops and portfolio reviews",
      syncedAt: "2026-10-21T00:00:00Z",
      stale: false,
    },
  ],
};
function state(shares: CalendarShare[] = []): AppState {
  return {
    ...preview,
    native: true,
    running: false,
    saving: false,
    settingsSection: "friends",
    sharing: {
      loaded: true,
      busy: false,
      token: "current",
      sources: [],
      shares,
    },
  };
}
it("sends only explicitly selected calendars and the chosen per-friend permission", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  const value = state();
  render(<FriendsSettings state={value} onAction={action} />);
  expect(action).not.toHaveBeenCalled();
  const send = screen.getByRole("button", {
    name: "Send sharing request",
  }) as HTMLButtonElement;
  expect(send.disabled).toBe(true);
  fireEvent.change(
    screen.getByRole("textbox", { name: "Their Calshot account email" }),
    { target: { value: "riley@example.invalid" } },
  );
  fireEvent.click(screen.getAllByRole("checkbox")[0]);
  fireEvent.change(screen.getByRole("combobox", { name: "Friend access" }), {
    target: { value: "busy" },
  });
  fireEvent.click(send);
  await waitFor(() =>
    expect(action).toHaveBeenCalledWith("requestCalendarShare", {
      email: "riley@example.invalid",
      calendarIDs: [value.calendars[0].id],
      permission: "busy",
      sharingToken: "current",
    }),
  );
  expect(screen.getByRole("status").textContent).toContain("Request sent");
});
it("requires deliberate acceptance and makes one-way access clear", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  render(<FriendsSettings state={state([grant])} onAction={action} />);
  expect(action).not.toHaveBeenCalled();
  expect(
    screen.getByText(/Accepting doesn’t share any of your calendars back/),
  ).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Accept sharing" }));
  await waitFor(() =>
    expect(action).toHaveBeenCalledWith("respondCalendarRequest", {
      requestID: "request",
      accept: true,
      sharingToken: "current",
    }),
  );
});
it("keeps failed requests and form values visible for recovery", async () => {
  const action = vi
    .fn()
    .mockRejectedValue(new Error("No verified Calshot account found."));
  render(<FriendsSettings state={state()} onAction={action} />);
  const email = screen.getByRole("textbox", {
    name: "Their Calshot account email",
  });
  fireEvent.change(email, { target: { value: "riley@example.invalid" } });
  fireEvent.click(screen.getAllByRole("checkbox")[0]);
  fireEvent.click(screen.getByRole("button", { name: "Send sharing request" }));
  await waitFor(() =>
    expect(screen.getByRole("alert").textContent).toContain("No verified"),
  );
  expect((email as HTMLInputElement).value).toBe("riley@example.invalid");
  expect((screen.getAllByRole("checkbox")[0] as HTMLInputElement).checked).toBe(
    true,
  );
});
it("edits access only when Save is pressed and carries the current permission", async () => {
  const action = vi.fn().mockResolvedValue(undefined);
  render(
    <FriendsSettings
      state={state([{ ...grant, outgoing: true, status: "accepted" }])}
      onAction={action}
    />,
  );
  fireEvent.change(
    screen.getByRole("combobox", { name: "Access for Riley Example" }),
    { target: { value: "busy" } },
  );
  expect(action).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Save access" }));
  await waitFor(() =>
    expect(action).toHaveBeenCalledWith(
      "manageCalendarShare",
      expect.objectContaining({
        permission: "busy",
        expectedPermission: "titles",
        stop: false,
      }),
    ),
  );
});
it("shows stale friend copies without treating them as current availability", () => {
  render(
    <FriendsSettings
      state={state([
        {
          ...grant,
          status: "accepted",
          calendars: [{ ...grant.calendars[0], stale: true }],
        },
      ])}
      onAction={vi.fn()}
    />,
  );
  expect(screen.getByRole("alert").textContent).toContain("out of date");
});
it("keeps friend calendars distinct, deduplicates grants, and removes unavailable data", () => {
  const value = state([
    { ...grant, status: "accepted" },
    { ...grant, id: "full", permission: "details", status: "accepted" },
  ]);
  expect(friendCalendars(value)).toHaveLength(1);
  expect(friendCalendars(value)[0].id).toBe("shared:full:studio");
  expect(friendCalendars(value)[0].isReadOnly).toBe(true);
  value.sharing!.error = "Offline";
  expect(friendCalendars(value)).toEqual([]);
});

it("does not present a sharing outage as an empty calendar", () => {
  const value = state([{ ...grant, status: "accepted" }]);
  value.calendars = []; value.sharing!.error = "Sharing is offline. Availability is unknown.";
  render(<CalendarPresentationProvider><CalendarPage state={value} onCommand={vi.fn().mockResolvedValue(undefined)} /></CalendarPresentationProvider>);
  expect(screen.getByRole("alert").textContent).toContain("Availability is unknown");
  expect(screen.getByRole("heading", { name: "Friend calendars couldn’t be verified" })).toBeTruthy();
  expect(screen.queryByText(/Nothing scheduled this/)).toBeNull();
});
