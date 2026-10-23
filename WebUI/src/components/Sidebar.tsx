import { useState, useRef } from "react";
import {
  CalendarDays,
  ListTodo,
  MessageSquare,
  History,
  Settings,
  ScanLine,
  PanelLeftClose,
  PanelLeftOpen,
} from "lucide-react";
import type { AppState, Page } from "../types";
import { CalendarSidebar } from "./CalendarSidebar";

export function Sidebar({
  state,
  onAction,
  captureLabel = "Capture",
}: {
  state: AppState;
  captureLabel?: string;
  onAction: (action: string, extra?: Record<string, unknown>) => Promise<void>;
}) {
  const [changing, setChanging] = useState(false);
  const [draftWidth, setDraftWidth] = useState<number | null>(null);
  const drag = useRef<{ x: number; width: number; value: number } | null>(null);
  const clamp = (value: number) => Math.min(320, Math.max(184, value));
  // One saved width for every section; only the user's resize changes it.
  const width = clamp(draftWidth ?? state.sidebarWidth ?? 228);
  const expanded = state.sidebarExpanded !== false;
  const navigation: [Page, string, typeof MessageSquare][] = [
    ["chat", "Assistant", MessageSquare],
    ["calendars", "Calendar", CalendarDays],
    ["tasks", "Tasks", ListTodo],
    ["library", "History", History],
    ["settings", "Settings", Settings],
  ];
  const pendingSharing =
    state.sharing?.shares.filter((s) => !s.outgoing && s.status === "pending")
      .length || 0;
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
      className={
        "sidebar" +
        (state.page === "calendars" ? " calendar-sidebar" : "") +
        (expanded ? "" : " sidebar-collapsed")
      }
      style={expanded ? { width } : undefined}
      aria-label="Sidebar"
    >
      {expanded && state.native && (
        <div
          className="sidebar-resizer"
          role="separator"
          aria-label="Resize sidebar"
          aria-orientation="vertical"
          aria-valuemin={184}
          aria-valuemax={320}
          aria-valuenow={width}
          tabIndex={0}
          onPointerDown={(event) => {
            if (event.button !== 0) return;
            event.preventDefault();
            event.currentTarget.setPointerCapture(event.pointerId);
            drag.current = { x: event.clientX, width, value: width };
          }}
          onPointerMove={(event) => {
            if (!drag.current) return;
            const value = clamp(
              drag.current.width + event.clientX - drag.current.x,
            );
            drag.current.value = value;
            setDraftWidth(value);
          }}
          onPointerUp={(event) => {
            if (!drag.current) return;
            const value = drag.current.value;
            drag.current = null;
            event.currentTarget.releasePointerCapture(event.pointerId);
            void onAction("sidebarWidth", { width: value }).finally(() =>
              setDraftWidth(null),
            );
          }}
          onPointerCancel={() => {
            drag.current = null;
            setDraftWidth(null);
          }}
          onKeyDown={(event) => {
            const value =
              event.key === "Home"
                ? 184
                : event.key === "End"
                  ? 320
                  : event.key === "ArrowLeft"
                    ? clamp(width - 16)
                    : event.key === "ArrowRight"
                      ? clamp(width + 16)
                      : null;
            if (value === null) return;
            event.preventDefault();
            void onAction("sidebarWidth", { width: value });
          }}
          onDoubleClick={() => void onAction("sidebarWidth", { width: 228 })}
        />
      )}
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
                {page === "settings" && pendingSharing > 0 && (
                  <small
                    className="sharing-request-count"
                    aria-label={`${pendingSharing} sharing requests`}
                  >
                    {pendingSharing}
                  </small>
                )}
              </button>
            );
          })}
        </nav>
        {expanded && state.page === "calendars" ? (
          <CalendarSidebar state={state} onAction={onAction} />
        ) : expanded ? (
          <div className="recent-tasks">
            <p className="sidebar-section">Recent conversations</p>
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
                Your conversations will show up here.
              </p>
            )}
          </div>
        ) : (
          <div className="sidebar-spacer" />
        )}
        <div className="sidebar-bottom">
          <button
            className="connection-link"
            aria-label={readiness + ". Manage calendar accounts"}
            title={readiness}
            onClick={() =>
              void onAction("navigate", {
                page: "settings",
                section: "calendars",
              })
            }
          >
            <span className={"dot " + (!ready ? "warn" : "")} />
            {expanded ? <span>{readiness}</span> : <CalendarDays size={17} />}
          </button>
          <button
            className="button primary"
            aria-label={
              captureLabel === "Capture" ? "Capture screen" : captureLabel
            }
            title={
              captureLabel === "Capture"
                ? "Capture screen · " + state.shortcut
                : captureLabel
            }
            disabled={state.saving || state.isCapturing}
            onClick={() => void onAction("capture")}
          >
            <ScanLine size={expanded ? 15 : 18} />
            {expanded && (
              <>
                {captureLabel}{" "}
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
