import { useState } from "react";
import {
  CalendarDays,
  MessageSquare,
  History,
  Settings,
  ScanLine,
  PanelLeftClose,
  PanelLeftOpen,
} from "lucide-react";
import type { AppState, Page } from "../types";

export function Sidebar({
  state,
  onAction,
}: {
  state: AppState;
  onAction: (action: string, extra?: Record<string, unknown>) => Promise<void>;
}) {
  const [changing, setChanging] = useState(false);
  const expanded = state.sidebarExpanded !== false;
  const navigation: [Page, string, typeof MessageSquare][] = [
    ["chat", "Assistant", MessageSquare],
    ["library", "History", History],
    ["calendars", "Calendars", CalendarDays],
    ["settings", "Settings", Settings],
  ];
  const ready = state.calendars.filter((c) => !c.unavailable).length;
  const readiness =
    state.calendarMessage?.startsWith("Connecting") ||
    state.calendarMessage?.startsWith("Checking")
      ? "Checking calendars…"
      : `${ready} calendar${ready === 1 ? "" : "s"} ready`;
  const toggle = async () => {
    setChanging(true);
    try {
      await onAction("sidebar", { expanded: !expanded });
    } finally {
      setChanging(false);
    }
  };
  return (
    <aside
      id="workspace-sidebar"
      className={"sidebar" + (expanded ? "" : " sidebar-collapsed")}
      aria-label="Sidebar"
    >
      <div className="sidebar-heading">
        {expanded && (
          <div className="brand">
            <CalendarDays size={19} />
            <span>Calshot</span>
          </div>
        )}
        <button
          className="icon-button sidebar-toggle"
          aria-label={expanded ? "Collapse sidebar" : "Expand sidebar"}
          title={expanded ? "Collapse sidebar" : "Expand sidebar"}
          aria-expanded={expanded}
          aria-controls="sidebar-content"
          disabled={changing}
          onClick={() => void toggle()}
        >
          {expanded ? (
            <PanelLeftClose size={17} />
          ) : (
            <PanelLeftOpen size={17} />
          )}
        </button>
      </div>
      <div id="sidebar-content" className="sidebar-content">
        <nav aria-label="Main navigation">
          {navigation.map(([page, label, Icon]) => {
            const active =
              state.page === page ||
              (page === "chat" && state.page === "capture");
            return (
              <button
                key={page}
                className={"nav-item " + (active ? "active" : "")}
                aria-current={active ? "page" : undefined}
                aria-label={label}
                title={expanded ? undefined : label}
                onClick={() => void onAction("navigate", { page })}
              >
                <Icon size={expanded ? 15 : 18} />
                {expanded && <span>{label}</span>}
              </button>
            );
          })}
        </nav>
        {expanded ? (
          <div className="recent-tasks">
            <p className="sidebar-section">Recent tasks</p>
            {state.memory.length ? (
              state.memory.slice(0, 7).map((record) => (
                <button
                  key={record.id}
                  className="recent-task"
                  disabled={
                    state.running ||
                    state.saving ||
                    state.isCapturing ||
                    state.isRecognizing
                  }
                  onClick={() =>
                    void onAction("restoreMemory", { recordID: record.id })
                  }
                >
                  <span className="truncate">{record.title}</span>
                  <small>
                    {record.completed
                      ? record.completed + " changes confirmed"
                      : record.count
                        ? "Needs review"
                        : "Conversation"}
                  </small>
                </button>
              ))
            ) : (
              <p className="fine-print" style={{ padding: "0 10px" }}>
                Your tasks will show up here.
              </p>
            )}
          </div>
        ) : (
          <div className="sidebar-spacer" />
        )}
        <div className="sidebar-bottom">
          <button
            className="connection-link"
            aria-label={readiness + ". Open calendars"}
            title={readiness}
            onClick={() => void onAction("navigate", { page: "calendars" })}
          >
            <span className={"dot " + (!ready ? "warn" : "")} />
            {expanded ? <span>{readiness}</span> : <CalendarDays size={17} />}
          </button>
          <button
            className="button primary"
            aria-label="Capture screen"
            title={"Capture screen · " + state.shortcut}
            disabled={state.saving || state.isCapturing}
            onClick={() => void onAction("capture")}
          >
            <ScanLine size={expanded ? 15 : 18} />
            {expanded && (
              <>
                Capture{" "}
                <small style={{ color: "inherit", opacity: 0.7 }}>
                  {state.shortcut}
                </small>
              </>
            )}
          </button>
        </div>
      </div>
    </aside>
  );
}
