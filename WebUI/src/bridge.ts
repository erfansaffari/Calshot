import { useSyncExternalStore } from "react";
import type { AppState, Command } from "./types";
import { preview } from "./preview";
const native = Boolean(window.webkit?.messageHandlers.calshot);
const previewEnabled =
  !native && new URLSearchParams(window.location.search).get("preview") === "1";
let state: AppState = !previewEnabled
  ? {
      ...preview,
      ready: false,
      native: true,
      messages: [],
      proposals: [],
      waitingApproval: false,
      calendars: [],
      accounts: [],
      memory: [],
    }
  : preview;
const listeners = new Set<() => void>();
const requests = new Map<
  string,
  {
    resolve: () => void;
    reject: (e: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }
>();
const update = (next: AppState) => {
  state = next;
  listeners.forEach((l) => l());
};
window.__calshotReceive = update;
window.__calshotReply = ({ id, ok, error }) => {
  const pending = requests.get(id);
  if (!pending) return;
  clearTimeout(pending.timer);
  requests.delete(id);
  ok
    ? pending.resolve()
    : pending.reject(new Error(error || "The action could not be completed."));
};
export function useAppState() {
  return useSyncExternalStore(
    (callback) => {
      listeners.add(callback);
      return () => {
        listeners.delete(callback);
      };
    },
    () => state,
  );
}
export async function command(message: Command): Promise<void> {
  if (!native) {
    if (!previewEnabled)
      throw new Error("The macOS connection is unavailable. Reopen Calshot.");
    simulate(message);
    return;
  }
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      requests.delete(id);
      reject(
        new Error(
          "This action is taking longer than expected. Check the current status before retrying.",
        ),
      );
    }, 180000);
    requests.set(id, { resolve, reject, timer });
    window.webkit!.messageHandlers.calshot.postMessage({ ...message, id });
  });
}
export function notify(message: Command) {
  void command(message).catch((error) => {
    update({ ...state, notice: error.message });
  });
}
if (native) notify({ action: "ready" });
function simulate(message: Command) {
  if (["refreshSharing", "syncSharing"].includes(message.action)) return;
  if (["requestCalendarShare", "respondCalendarRequest", "manageCalendarShare", "withdrawSharingCalendar"].includes(message.action)) throw new Error("Design preview only. No request was sent and no sharing access changed.");
  if (
    ["notchLayout", "collapseNotch", "openWorkspace"].includes(message.action)
  )
    return;
  if (message.action === "navigate")
    update({
      ...state,
      page: message.page as AppState["page"],
      settingsSection: (message.section ||
        "general") as AppState["settingsSection"],
    });
  else if (message.action === "loadCalendarEvents") {
    const ids = message.calendarIDs as string[];
    const rangeStart = new Date(String(message.start));
    const today = new Date();
    const day = today >= rangeStart && today < new Date(String(message.end)) ? today : new Date(rangeStart);
    day.setDate(day.getDate() - day.getDay() + 1);
    day.setHours(10, 0, 0, 0);
    const end = new Date(day);
    end.setHours(11, 0, 0, 0);
    const samples = [
      "Project check-in",
      "Studio session",
      "Dinner reservation",
      "Course registration opens",
      "Weekend trip",
    ];
    update({
      ...state,
      calendarView: {
        loaded: true,
        loading: false,
        start: String(message.start),
        end: String(message.end),
        errors: [],
        events: ids.length
          ? samples.map((title, i) => {
              const start = new Date(day);
              start.setDate(start.getDate() + (i === 1 ? 0 : i));
              start.setHours(i === 1 ? 10 : i === 2 ? 18 : 10, i === 1 ? 30 : 0, 0, 0);
              const finish = new Date(start);
              finish.setHours(start.getHours() + (i === 0 ? 2 : 1));
              if (i === 3) { start.setHours(0, 0, 0, 0); finish.setDate(start.getDate() + 1); finish.setHours(0, 0, 0, 0); }
              const calendarID = ids[i % ids.length],
                calendar = state.calendars.find((c) => c.id === calendarID);
              return {
                eventIdentifier: "fixture-event-" + i,
                calendarIdentifier: calendarID,
                title,
                start: start.toISOString(),
                end: finish.toISOString(),
                isAllDay: i === 3,
                calendarName: calendar?.title || "Calendar",
                sourceName: calendar?.sourceName || "Preview",
                location: i === 2 ? "Market Street" : "",
                notes:
                  "Fictional preview event. No real calendars are changed.",
              };
            })
          : [],
      },
    });
  } else if (message.action === "newTask")
    update({
      ...state,
      messages: [],
      proposals: [],
      waitingApproval: false,
      selectedCount: 0,
      canApprove: false,
    });
  else if (message.action === "selectProposal")
    update({
      ...state,
      proposals: state.proposals.map((p) =>
        p.id === message.proposalID
          ? { ...p, isSelected: Boolean(message.selected) }
          : p,
      ),
      selectedCount: state.proposals.filter((p) =>
        p.id === message.proposalID ? Boolean(message.selected) : p.isSelected,
      ).length,
    });
  else if (message.action === "skipApproval")
    update({
      ...state,
      waitingApproval: false,
      proposals: state.proposals.map((p) => ({ ...p, isSelected: false })),
      selectedCount: 0,
    });
  else if (message.action === "approve")
    update({
      ...state,
      waitingApproval: false,
      proposals: state.proposals.map((p) =>
        p.isSelected && !p.isFinished
          ? {
              ...p,
              isFinished: true,
              state: p.operation === "create" ? "added" : "moved",
              status: p.operation === "create" ? "Added" : "Moved",
              isSelected: false,
            }
          : p,
      ),
      selectedCount: 0,
      messages: [
        ...state.messages,
        {
          role: "assistant",
          content:
            "Preview: both shifts were moved. No real calendars were changed.",
        },
      ],
    });
  else if (message.action === "compareDuplicate") {
    const item = state.proposals.find((p) => p.id === message.proposalID);
    if (item)
      update({
        ...state,
        duplicateComparisons: {
          ...state.duplicateComparisons,
          [item.id]: [{ ...item.draft, title: "BIOL midterm" }],
        },
      });
  } else if (message.action === "allowDuplicate")
    update({
      ...state,
      proposals: state.proposals.map((p) =>
        p.id === message.proposalID
          ? { ...p, allowDuplicate: true, canSelect: true, isSelected: true }
          : p,
      ),
    });
  else if (message.action === "selectCalendar")
    update({ ...state, selectedCalendarID: String(message.calendarID) });
  else if (message.action === "sidebarWidth")
    update({ ...state, sidebarWidth: Number(message.width) });
  else if (message.action === "sidebar")
    update({ ...state, sidebarExpanded: Boolean(message.expanded) });
  else if (message.action === "appearance")
    update({
      ...state,
      settings: {
        ...state.settings,
        appearance: message.mode as AppState["settings"]["appearance"],
      },
    });
  else if (message.action === "provider")
    update({
      ...state,
      settings: { ...state.settings, useAPIKey: Boolean(message.useAPIKey) },
    });
  else if (message.action === "send" || message.action === "startCalendarTask")
    update({
      ...state,
      ...(message.action === "startCalendarTask" ? {
        page: "chat" as const, imageURL: undefined, ocr: "", proposals: [],
        summary: undefined, status: undefined, agentError: undefined,
        captureID: crypto.randomUUID(), streaming: "", agentStatus: undefined, question: undefined,
        waitingApproval: false, selectedCount: 0, canApprove: false,
      } : {}),
      messages: [
        ...(message.action === "startCalendarTask" ? [] : state.messages),
        { role: "user", content: String(message.text) },
        {
          role: "assistant",
          content:
            "This is the interactive design preview. Open Calshot on your Mac to use screenshots and your real calendars.",
        },
      ],
    });
  else if (message.action === "restoreMemory")
    update({ ...state, page: "chat" });
  else if (message.action === "dismissNotice")
    update({ ...state, notice: undefined });
  else if (message.action === "answer" || message.action === "cancelQuestion")
    update({
      ...state,
      question: undefined,
      running: false,
      messages: [
        ...state.messages,
        {
          role: "user",
          content:
            message.action === "answer"
              ? String(message.answer)
              : "Cancelled the question.",
        },
        {
          role: "assistant",
          content: "Preview answer received. No calendars were changed.",
        },
      ],
    });
  else if (message.action === "stop")
    update({ ...state, running: false, waitingApproval: false, taskReview: undefined });
  else if (message.action === "approveTaskChange" || message.action === "cancelTaskChange") {
    const approved = message.action === "approveTaskChange";
    update({ ...state, running: false, taskReview: undefined, taskOutcome: {
      id: crypto.randomUUID(), status: approved ? "saved" : "declined", viaSavedPermission: false,
      headline: approved ? "Preview: task change saved" : "Nothing changed",
      rows: approved ? (state.taskReview?.rows || []).slice(0, 12).map((r) => ({ id: r.id, title: r.title, status: "saved" })) : [] } });
  } else if (message.action === "loadAgentPermissions") return;
  else if (message.action === "saveAgentPermissions" && state.agentPermissions) {
    const families = (message.families || {}) as Record<string, boolean>;
    update({ ...state, agentPermissions: { ...state.agentPermissions, revision: state.agentPermissions.revision + 1,
      notice: "Preview only. Nothing was saved.", expiresAt: new Date(Date.now() + Number(message.days) * 86400000).toISOString(),
      families: state.agentPermissions.families.map((f) => ({ ...f, enabled: Boolean(families[f.id]), expired: false })) } });
  }
  else
    update({
      ...state,
      notice:
        "This action is available in the macOS app. Preview data is separate from your calendars.",
    });
}
