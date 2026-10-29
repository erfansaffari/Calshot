import { MacCalendarConnectionHint } from "../components/ui";
import { useEffect, useState } from "react";
import {
  CalendarDays,
  RefreshCw,
  ShieldCheck,
  Search,
  History as HistoryIcon,
  ArrowRight,
  KeyRound,
  Check,
  Image as ImageIcon,
  ExternalLink,
  Trash2,
} from "lucide-react";
import type { AppState, PersonalMemoryItem } from "../types";
import { command } from "../bridge";
import { SoftwareUpdates } from "./SoftwareUpdates";
import { FriendsSettings } from "./FriendsSettings";
import { AgentTaskPermissions } from "../components/AgentTaskPermissions";
import {
  Badge,
  Empty,
  InlineError,
  Modal,
  Select,
  Spinner,
  formatDate,
} from "../components/ui";
function useAction() {
  const [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [notice, setNotice] = useState("");
  return {
    error,
    busy,
    notice,
    run: async (action: string, extra: Record<string, unknown> = {}) => {
      setBusy(true);
      setError("");
      setNotice("");
      try {
        await command({ action, ...extra });
        return true;
      } catch (e) {
        setError((e as Error).message);
        return false;
      } finally {
        setBusy(false);
      }
    },
    setNotice,
  };
}
function AccountSyncCard({ state }: { state: AppState }) {
  const a = useAction();
  const sync = state.accountSync;
  if (!state.auth?.signedIn || !sync) return null;
  const local = sync.devices[sync.deviceID]?.connections || [];
  const otherAccounts = Object.entries(sync.devices).flatMap(([id, device]) =>
    id === sync.deviceID
      ? []
      : device.connections.map((connection) => ({
          ...connection,
          device: device.name,
        })),
  );
  const unique = otherAccounts.filter(
    (item, i) =>
      otherAccounts.findIndex((other) => other.key === item.key) === i,
  );
  return (
    <section aria-label="Account sync">
      <h2 className="section-label">Account & sync</h2>
      <div className="card settings-card">
        <div className="settings-row">
          <div>
            <h3>
              {sync.displayName || state.auth.email || "Your Calshot account"}
            </h3>
            <p>{sync.busy ? "Syncing your account…" : sync.status}</p>
            {sync.lastSyncedAt && (
              <small>Last synced {formatDate(sync.lastSyncedAt)}</small>
            )}
          </div>
          <button
            className="button secondary"
            disabled={sync.busy || a.busy || state.running || state.saving}
            onClick={() => void a.run("syncAccount")}
          >
            {sync.busy ? <Spinner /> : <RefreshCw size={14} />} Sync now
          </button>
        </div>
        <div className="settings-row">
          <div>
            <h3>Signed in to Calshot</h3>
            <p>{state.auth.email}</p>
          </div>
          <button
            className="button secondary"
            disabled={
              a.busy ||
              state.running ||
              state.saving ||
              state.isCapturing ||
              state.isRecognizing
            }
            onClick={() => void a.run("authSignOut")}
          >
            Sign out
          </button>
        </div>
        <InlineError message={sync.error || a.error} />
        <p className="fine-print">
          Profile, appearance, sidebar, connected-account list and task history
          sync privately. Screenshots and credentials stay on each Mac.
          Restoring history never repeats calendar changes.
        </p>
        {!!unique.length && (
          <div className="settings-group">
            <h3>Accounts from your other devices</h3>
            {unique.map((item) => (
              <div className="settings-row" key={item.key}>
                <div>
                  <h3>{item.label}</h3>
                  <p>
                    {item.provider} · {item.device}
                  </p>
                  <small>
                    {local.some((account) => account.key === item.key)
                      ? "Also connected on this Mac"
                      : "Reconnect on this Mac to use this account"}
                  </small>
                </div>
                <button
                  className="button secondary"
                  onClick={() =>
                    void a.run("navigate", {
                      page: "settings",
                      section: item.provider === "chatgpt" ? "ai" : "calendars",
                    })
                  }
                >
                  Manage connection
                </button>
              </div>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}
function WebCalendarSync({ state }: { state: AppState }) {
  const a = useAction();
  const sync = state.webCalendarSync;
  if (!state.auth?.signedIn || !sync) return null;
  const calendars = state.calendars.filter((c) => !c.unavailable);
  const busy = a.busy || sync.busy || state.running || state.saving;
  return (
    <section aria-label="Calendar web sync">
      <h2 className="section-label">Your calendars on the web</h2>
      <div className="card settings-card">
        <div className="settings-row">
          <div>
            <h3>Sync selected calendars to Calshot</h3>
            <p>
              See these calendars on the website, even when your Mac is offline.
            </p>
          </div>
          <button
            className="button secondary"
            disabled={busy}
            onClick={() => void a.run("syncMacCalendars")}
          >
            {sync.busy ? <Spinner /> : <RefreshCw size={14} />} Refresh web sync
          </button>
        </div>
        <p className="fine-print">
          Choose each calendar to upload its event titles, times and locations
          privately to your account. Updates happen while Calshot is running on
          this Mac, covering the past 7 days and next 55 days. Stopping sync
          removes the web copy and keeps your original events.
        </p>
        <InlineError message={a.error || sync.error || undefined} />
        {!calendars.length && (
          <p className="fine-print">
            Allow Calendar access to choose calendars.
          </p>
        )}
        {sync.mirrors
          .filter(
            (m) =>
              m.enabled &&
              !calendars.some((c) => sync.sourceKeys[c.id] === m.sourceKey),
          )
          .map((m) => (
            <div className="settings-row" key={m.id}>
              <div>
                <h3>{m.name}</h3>
                <p>
                  This calendar is unavailable on this Mac. Its web copy may be
                  out of date.
                </p>
                <InlineError message={m.error} />
              </div>
              <button
                className="button secondary"
                disabled={busy}
                onClick={() =>
                  void a.run("stopMacCalendarSync", { mirrorID: m.id })
                }
              >
                Stop syncing
              </button>
            </div>
          ))}
        {calendars.map((c) => {
          const mirror = sync.mirrors.find(
            (m) => m.sourceKey === sync.sourceKeys[c.id],
          );
          return (
            <div className="web-sync-calendar" key={c.id}>
              <div className="settings-row">
                <div>
                  <h3>{c.title}</h3>
                  <p>
                    {c.sourceName} ·{" "}
                    {mirror?.enabled
                      ? mirror.syncedAt
                        ? `Last synced ${formatDate(mirror.syncedAt)}`
                        : "Waiting for the first sync"
                      : "Only on this Mac"}
                  </p>
                </div>
                <button
                  className="button secondary"
                  disabled={busy}
                  onClick={() =>
                    void a.run("setMacCalendarSync", {
                      calendarID: c.id,
                      enabled: !mirror?.enabled,
                    })
                  }
                >
                  {mirror?.enabled ? "Stop syncing" : "Sync to web"}
                </button>
              </div>
              {mirror?.enabled &&
                !mirror.complete &&
                mirror.syncedAt &&
                !mirror.error && (
                  <p className="fine-print">
                    The web copy may be incomplete. Refresh to retry.
                  </p>
                )}
              <InlineError
                message={mirror?.enabled ? mirror.error : undefined}
              />
            </div>
          );
        })}
      </div>
    </section>
  );
}
export function CalendarConnections({ state }: { state: AppState }) {
  const a = useAction(),
    [disconnect, setDisconnect] = useState<string>();
  const available = state.calendars.filter((c) => !c.unavailable),
    writable = available.filter((c) => !c.isReadOnly);
  const groups = available.reduce<Record<string, typeof available>>(
    (groups, c) => {
      (groups[c.sourceName || c.provider] ??= []).push(c);
      return groups;
    },
    {},
  );
  return (
    <div className="connections-settings">
      <div className="connections-inner">
        <header className="page-title">
          <h2>Calendar accounts</h2>
          <button
            className="button secondary"
            disabled={a.busy || state.running || state.saving}
            onClick={() => void a.run("refreshCalendars")}
          >
            <RefreshCw size={14} />
            Refresh
          </button>
        </header>
        <InlineError message={a.error} />
        <div className="card connection-summary">
          <ShieldCheck size={22} color="var(--success)" />
          <div>
            <h3>
              {available.length} calendars ready · {writable.length} you can add
              to
            </h3>
            <small>
              Existing macOS calendars are reused. Each calendar appears once.
            </small>
          </div>
        </div>
        {state.calendarMessage && (
          <div className="notice" style={{ margin: 0 }}>
            <p>{state.calendarMessage}</p>
            <button
              className="button secondary"
              onClick={() => void a.run("calendarSettings")}
            >
              Calendar access
            </button>
          </div>
        )}
        <section>
          <h2 className="section-label">New events go to</h2>
          <Select
            label="Default destination for new events"
            value={state.selectedCalendarID}
            disabled={a.busy || state.saving}
            onChange={(calendarID) =>
              void a.run("selectCalendar", { calendarID })
            }
          >
            {!writable.length && (
              <option value="">Connect a writable calendar</option>
            )}
            {writable.map((c) => (
              <option key={c.id} value={c.id}>
                {c.title} · {c.sourceName}
              </option>
            ))}
          </Select>
          <p className="fine-print" style={{ marginTop: 7 }}>
            You can choose a different calendar in each task.
          </p>
        </section>
        <WebCalendarSync state={state} />
        <section>
          <h2 className="section-label">Available calendars</h2>
          <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            {Object.entries(groups).map(([name, calendars]) => (
              <article className="card" key={name}>
                <header className="account-header">
                  <span className="provider-icon">
                    <CalendarDays size={17} />
                  </span>
                  <div className="account-identity">
                    <h3>{name}</h3>
                    <small>
                      {calendars?.some((c) => c.direct)
                        ? "Direct calendar access"
                        : "Through macOS Calendar"}
                    </small>
                  </div>
                  <Badge tone="success">Ready</Badge>
                </header>
                {calendars?.map((c) => (
                  <div className="calendar-row" key={c.id}>
                    <span className="dot" />
                    <span>
                      {c.title}{" "}
                      {c.id === state.selectedCalendarID && (
                        <Badge>Default</Badge>
                      )}
                    </span>
                    <small>
                      {c.isReadOnly ? "Read-only · search only" : "Can edit"}
                    </small>
                  </div>
                ))}
              </article>
            ))}
            {!available.length && (
              <Empty
                icon={<CalendarDays size={28} />}
                title="Connect your calendars"
              >
                Allow macOS Calendar access or connect Google below. Calshot
                asks before making changes.
              </Empty>
            )}
          </div>
        </section>
        {!!state.accounts.length && (
          <section>
            <h2 className="section-label">Direct sign-ins</h2>
            <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
              {state.accounts.map((account) => (
                <article className="card" key={account.id}>
                  <header className="account-header">
                    <span className="provider-icon">
                      {account.provider === "google"
                        ? "G"
                        : account.provider === "outlook"
                          ? "O"
                          : "i"}
                    </span>
                    <div className="account-identity">
                      <h3>{account.email}</h3>
                      <small>
                        {account.provider === "google"
                          ? "Google"
                          : account.provider === "icloud"
                            ? "iCloud"
                            : "Outlook"}{" "}
                        · direct sign-in
                      </small>
                    </div>
                    <Badge tone={account.unavailable ? "warning" : "neutral"}>
                      {account.unavailable ? "Needs attention" : "Signed in"}
                    </Badge>
                  </header>
                  {account.unavailable && (
                    <div className="account-error">
                      <InlineError message="Sign-in is saved, but this connection couldn't load its calendars. An existing macOS connection may still work.">
                        <button
                          className="button secondary"
                          disabled={a.busy || state.connecting}
                          onClick={() =>
                            void a.run(
                              account.provider === "google"
                                ? "connectGoogle"
                                : "advancedSettings",
                            )
                          }
                        >
                          Reconnect
                        </button>
                      </InlineError>
                    </div>
                  )}
                  <div className="account-note">
                    <button
                      className="text-button danger"
                      disabled={state.running || state.saving}
                      onClick={() => setDisconnect(account.id)}
                    >
                      Disconnect direct sign-in
                    </button>
                  </div>
                </article>
              ))}
            </div>
          </section>
        )}
        {state.accountMessage && (
          <div
            className="notice"
            style={{ margin: 0 }}
            role={state.accountError ? "alert" : "status"}
          >
            <p>{state.accountMessage}</p>
          </div>
        )}
        <section>
          <h2 className="section-label">Add an account</h2>
          <div className="card settings-card">
            <div className="settings-row">
              <div>
                <h3>Google</h3>
                <p>
                  Sign in in your browser, then return here. Existing calendars
                  are reused.
                </p>
              </div>
              <button
                className="button secondary"
                disabled={a.busy || state.connecting}
                onClick={() => void a.run("connectGoogle")}
              >
                {state.connecting && state.connectingProvider === "google" ? (
                  <Spinner />
                ) : null}
                {state.connecting ? "Connecting…" : "Connect"}
              </button>
            </div>
            <MacCalendarConnectionHint
              disabled={a.busy || state.connecting}
              onOpen={() => void a.run("internetAccountsSettings")}
            />
            <div className="settings-row">
              <div>
                <h3>Outlook / Microsoft 365</h3>
                <p>
                  Direct sign-in is pending registration. Outlook calendars
                  already added to macOS can be used.
                </p>
              </div>
              <Badge>Coming later</Badge>
            </div>
            <div className="settings-row">
              <div>
                <h3>iCloud, direct</h3>
                <p>
                  Uses an app-specific password. This route is not
                  live-verified; macOS access is recommended.
                </p>
              </div>
              <button
                className="button secondary"
                onClick={() => void a.run("advancedSettings")}
              >
                Beta setup
              </button>
            </div>
            {state.connecting && (
              <button
                className="text-button"
                onClick={() => void a.run("cancelConnection")}
              >
                Cancel sign-in
              </button>
            )}
          </div>
          <p className="fine-print" style={{ marginTop: 12 }}>
            Using Notion Calendar? Connect its underlying supported calendar
            account. Calshot doesn't connect to Notion database dates.
          </p>
        </section>
        {disconnect && (
          <Modal
            title="Disconnect this sign-in?"
            onClose={() => setDisconnect(undefined)}
          >
            <p>
              This removes Calshot's direct access for this account. Calendar
              events are not deleted. A connection through macOS can remain
              available.
            </p>
            <footer>
              <button
                className="button secondary"
                onClick={() => setDisconnect(undefined)}
              >
                Keep connected
              </button>
              <button
                className="button secondary danger"
                disabled={a.busy}
                onClick={async () => {
                  if (
                    await a.run("disconnectAccount", { accountID: disconnect })
                  )
                    setDisconnect(undefined);
                }}
              >
                Disconnect
              </button>
            </footer>
            <InlineError message={a.error} />
          </Modal>
        )}
      </div>
    </div>
  );
}
export function HistoryPage({ state }: { state: AppState }) {
  const a = useAction(),
    [query, setQuery] = useState(""),
    [selected, setSelected] = useState<string>(),
    [deleting, setDeleting] = useState(false);
  const rows = state.memory.filter((r) =>
      r.title.toLowerCase().includes(query.toLowerCase()),
    ),
    record = rows.find((r) => r.id === selected) || rows[0];
  return (
    <div className="page-scroll">
      <div className="page-inner">
        <header className="page-title">
          <h1>History</h1>
        </header>
        <input
          className="search-input"
          type="search"
          aria-label="Search history"
          placeholder="Search your tasks…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <InlineError message={a.error} />
        {!rows.length ? (
          <Empty
            icon={<HistoryIcon size={28} />}
            title={query ? "No matching tasks" : "Your tasks will live here"}
          >
            {query
              ? "Try another search."
              : "Capture a screenshot or start a conversation. You can return to it here."}
          </Empty>
        ) : (
          <div className="history-layout">
            <div className="history-list">
              {rows.map((r) => (
                <button
                  className={
                    "history-item " + (record?.id === r.id ? "selected" : "")
                  }
                  key={r.id}
                  onClick={() => setSelected(r.id)}
                >
                  {r.imageURL ? (
                    <img src={r.imageURL} alt="" />
                  ) : (
                    <HistoryIcon size={24} />
                  )}
                  <div>
                    <h3 className="truncate">{r.title}</h3>
                    <small>
                      {r.completed} confirmed · {r.count - r.completed} other
                      items
                      <br />
                      {formatDate(r.createdAt, undefined, { year: "numeric" })}
                    </small>
                  </div>
                </button>
              ))}
            </div>
            {record && (
              <article className="card history-detail">
                <h2>{record.title}</h2>
                <small>
                  {formatDate(record.createdAt, undefined, {
                    year: "numeric",
                    hour: "numeric",
                    minute: "2-digit",
                  })}
                </small>
                {record.imageURL && (
                  <img src={record.imageURL} alt="Task screenshot" />
                )}
                <div>
                  <Badge tone="success">{record.completed} confirmed</Badge>{" "}
                  <Badge>{record.count - record.completed} other items</Badge>
                </div>
                <button
                  className="button primary"
                  disabled={
                    a.busy ||
                    state.running ||
                    state.saving ||
                    state.isRecognizing
                  }
                  onClick={() =>
                    void a.run("restoreMemory", { recordID: record.id })
                  }
                >
                  Continue this task
                  <ArrowRight size={14} />
                </button>
                <p className="fine-print">
                  Continue with the conversation and source. Completed changes
                  stay completed; nothing is redone automatically.
                </p>
                <hr
                  style={{
                    border: 0,
                    borderTop: "1px solid var(--line)",
                    width: "100%",
                  }}
                />
                <p className="fine-print">
                  Deleting removes this task's local history and screenshot. It
                  does not delete calendar events.
                </p>
                <button
                  className="text-button danger"
                  disabled={state.running || state.saving}
                  onClick={() => setDeleting(true)}
                >
                  Delete from history…
                </button>
              </article>
            )}
          </div>
        )}
        {deleting && record && (
          <Modal
            title="Delete this task from History?"
            onClose={() => setDeleting(false)}
          >
            <p>
              Its screenshot and conversation will be removed from this Mac.
              Calendar events stay unchanged.
            </p>
            <footer>
              <button
                className="button secondary"
                onClick={() => setDeleting(false)}
              >
                Cancel
              </button>
              <button
                className="button secondary danger"
                disabled={a.busy}
                onClick={async () => {
                  if (await a.run("deleteMemory", { recordID: record.id }))
                    setDeleting(false);
                }}
              >
                Delete local history
              </button>
            </footer>
            <InlineError message={a.error} />
          </Modal>
        )}
      </div>
    </div>
  );
}
export function SettingsPage({ state }: { state: AppState }) {
  const a = useAction(),
    [editingKey, setEditingKey] = useState(false),
    [key, setKey] = useState("");
  const [tab, setTab] = useState(state.settingsSection || "general");
  useEffect(() => {
    setTab(state.settingsSection || "general");
  }, [state.settingsSection]);
  const s = state.settings,
    locked = state.running || state.saving || a.busy;
  return (
    <div className="page-scroll">
      <div className="page-inner settings-page">
        <header className="page-title">
          <h1>Settings</h1>
        </header>
        <nav className="settings-tabs" aria-label="Settings sections">
          {(
            [
              ["general", "General"],
              ["calendars", "Calendar accounts"],
              ["friends", "Friends & sharing"],
              ["ai", "AI service"],
              ["voice", "Voice"],
              ["privacy", "Privacy & permissions"],
            ] as const
          ).map(([id, label]) => (
            <button
              key={id}
              className={tab === id ? "active" : ""}
              aria-current={tab === id ? "page" : undefined}
              onClick={() => {
                setTab(id);
                void a.run("navigate", { page: "settings", section: id });
              }}
            >
              {label}
            </button>
          ))}
        </nav>
        {tab === "voice" && <VoiceSettings state={state} />}
        {tab === "calendars" && <CalendarConnections state={state} />}
        {tab === "friends" && (
          <FriendsSettings
            state={state}
            onAction={(action, extra) => command({ action, ...extra })}
          />
        )}
        <InlineError message={a.error} />
        {state.notice && (
          <div className="notice" style={{ margin: 0 }}>
            <p>{state.notice}</p>
          </div>
        )}
        {tab === "general" && <AccountSyncCard state={state} />}
        {tab === "general" && (
          <SoftwareUpdates
            state={state}
            onAction={(action, extra) => command({ action, ...extra })}
          />
        )}
        {tab === "general" && (
          <section>
            <h2 className="section-label">Appearance & capture</h2>
            <div className="card settings-card">
              <div className="settings-row">
                <div>
                  <h3>Appearance</h3>
                  <p>System follows your Mac.</p>
                </div>
                <Select
                  label="Appearance"
                  value={s.appearance || "system"}
                  disabled={a.busy}
                  onChange={(mode) => void a.run("appearance", { mode })}
                >
                  <option value="system">System</option>
                  <option value="light">Light</option>
                  <option value="dark">Dark</option>
                </Select>
              </div>
              <div className="settings-row">
                <div>
                  <h3>Capture shortcut</h3>
                  <p>Change it in native preferences.</p>
                </div>
                <button
                  className="button secondary"
                  onClick={() => void a.run("advancedSettings")}
                >
                  {state.shortcut}
                </button>
              </div>
              <div className="settings-row"><div><h3>Voice shortcut</h3><p>Configure voice and its shortcut.</p></div><button className="button secondary" onClick={() => { setTab("voice"); void a.run("navigate", { page: "settings", section: "voice" }); }}>{state.voiceShortcut || "⌃⇧V"}</button></div>
              <div className="settings-row">
                <div>
                  <h3>Show Calshot in the notch</h3>
                  <p>
                    Point at the top of the screen to capture or ask. When off,
                    tasks open here.
                  </p>
                </div>
                <input
                  type="checkbox"
                  aria-label="Show Calshot in the notch"
                  checked={s.notchEnabled !== false}
                  disabled={a.busy}
                  onChange={(e) =>
                    void a.run("notchEnabled", { enabled: e.target.checked })
                  }
                />
              </div>
              <div className="settings-row">
                <div>
                  <h3>Copy captures to clipboard</h3>
                </div>
                <input
                  type="checkbox"
                  aria-label="Copy captures to clipboard"
                  checked={s.copyCaptures}
                  onChange={(e) =>
                    void a.run("copyCaptures", { enabled: e.target.checked })
                  }
                />
              </div>
            </div>
          </section>
        )}
        {tab === "ai" && (
          <section>
            <h2 className="section-label">AI service</h2>
            <div className="card settings-card">
              <div className="settings-row">
                <div>
                  <h3>AI service for new requests</h3>
                  <p>API usage is billed by OpenAI, separately from ChatGPT.</p>
                </div>
                <Select
                  label="AI service"
                  value={s.useAPIKey ? "api" : "plan"}
                  disabled={locked}
                  onChange={(value) =>
                    void a.run("provider", { useAPIKey: value === "api" })
                  }
                >
                  <option value="api">OpenAI API key</option>
                  <option value="plan">ChatGPT plan</option>
                </Select>
              </div>
              <div className="settings-row">
                <div>
                  <h3>
                    OpenAI API key{" "}
                    {s.useAPIKey && <Badge tone="success">In use</Badge>}
                  </h3>
                  <p>
                    {s.apiKeySaved
                      ? "Saved in your macOS Keychain."
                      : "No key saved."}
                  </p>
                </div>
                <div className="settings-actions">
                  <button
                    className="button secondary"
                    disabled={locked}
                    onClick={() => setEditingKey(true)}
                  >
                    {s.apiKeySaved ? "Replace key" : "Add key"}
                  </button>
                  <button
                    className="button secondary"
                    disabled={locked || !s.apiKeySaved}
                    onClick={() => void a.run("testAI")}
                  >
                    Test connection
                  </button>
                </div>
              </div>
              <div className="settings-row">
                <div>
                  <h3>
                    ChatGPT plan{" "}
                    {s.chatGPTPlan && (
                      <Badge tone={s.chatGPTError ? "warning" : "success"}>
                        {s.chatGPTError ? "Service issue" : "Signed in"}
                      </Badge>
                    )}
                  </h3>
                  <p>
                    {s.chatGPTEmail
                      ? (s.chatGPTPlan ? "Signed in as " : "Saved account: ") +
                        s.chatGPTEmail +
                        "."
                      : "Not connected."}{" "}
                    {s.chatGPTError
                      ? s.chatGPTPlan
                        ? "Your sign-in is kept while the service is unavailable."
                        : "Reconnect to authorize ChatGPT plan access."
                      : ""}
                  </p>
                  {s.chatGPTError && (
                    <details>
                      <summary>Service details</summary>
                      <p>{s.chatGPTError}</p>
                    </details>
                  )}
                </div>
                <div className="settings-actions">
                  {s.chatGPTConnecting ? (
                    <>
                      <span role="status">
                        Finish ChatGPT sign-in in your browser…
                      </span>
                      <button
                        className="button secondary"
                        onClick={() => void a.run("cancelChatGPT")}
                      >
                        Cancel
                      </button>
                    </>
                  ) : (
                    <>
                      <button
                        className="button secondary"
                        disabled={locked}
                        onClick={() => void a.run("connectChatGPT")}
                      >
                        {s.chatGPTEmail ? "Reconnect" : "Continue with ChatGPT"}
                      </button>
                      {s.chatGPTPlan && (
                        <>
                          <button
                            className="button secondary"
                            disabled={locked}
                            onClick={() => void a.run("refreshChatGPT")}
                          >
                            Check again
                          </button>
                          <button
                            className="button secondary"
                            disabled={locked}
                            onClick={() => void a.run("testChatGPT")}
                          >
                            Test ChatGPT
                          </button>
                        </>
                      )}
                    </>
                  )}
                </div>
              </div>
              {s.models.length > 0 && (
                <div className="settings-row">
                  <h3>
                    <label htmlFor="chatgpt-model">ChatGPT model</label>
                  </h3>
                  <select
                    id="chatgpt-model"
                    value={s.useAPIKey ? "" : s.model}
                    disabled={locked || s.chatGPTConnecting}
                    onChange={(e) =>
                      void a.run("selectChatGPTModel", {
                        model: e.target.value,
                      })
                    }
                  >
                    {s.useAPIKey && (
                      <option value="" disabled>
                        Choose after selecting ChatGPT plan
                      </option>
                    )}
                    {s.models.map((m) => (
                      <option key={m.id} value={m.id}>
                        {m.name}
                      </option>
                    ))}
                  </select>
                </div>
              )}
              <div className="settings-row">
                <div>
                  <h3>Calendar agent</h3>
                  <p>Use the chosen service for screenshots and chat.</p>
                </div>
                <input
                  type="checkbox"
                  aria-label="Enable calendar agent"
                  checked={s.agentEnabled}
                  disabled={locked}
                  onChange={(e) =>
                    void a.run("agentEnabled", { enabled: e.target.checked })
                  }
                />
              </div>
              <p className="fine-print">
                Your Calshot account and calendar permissions are separate from
                AI billing.
              </p>
            </div>
          </section>
        )}
        {tab === "privacy" && (
          <section>
            <h2 className="section-label">Permissions</h2>
            <div className="card settings-card">
              <div className="settings-row">
                <div>
                  <h3>Screen Recording</h3>
                  <p>
                    Needed to capture your screen. Drag Calshot into the list
                    and turn it on; macOS may ask you to reopen Calshot.
                  </p>
                </div>
                <button
                  className="button secondary"
                  onClick={() => void a.run("screenSettings")}
                >
                  {state.screenPermissionNeeded
                    ? "Allow access"
                    : "System Settings"}
                </button>
              </div>
              <div className="settings-row">
                <div>
                  <h3>Calendars</h3>
                  <p>Read your calendars and make approved changes.</p>
                </div>
                <button
                  className="button secondary"
                  onClick={() => void a.run("calendarSettings")}
                >
                  System Settings
                </button>
              </div>
            </div>
          </section>
        )}
        {tab === "privacy" && <PersonalMemorySettings state={state} />}
        {tab === "privacy" && <AgentTaskPermissions state={state} />}
        {tab === "privacy" && (
          <section>
            <h2 className="section-label">Privacy & storage</h2>
            <div className="card settings-card">
              <p className="fine-print">
                When a task runs, Calshot sends your screenshot, request, needed
                text, relevant calendar results and a limited amount of related
                history to your chosen OpenAI service. Requests ask not to store
                responses for later use; OpenAI processes them under its own
                policies.
              </p>
              <div className="settings-row">
                <div>
                  <h3>History on this Mac</h3>
                  <p>
                    {state.memory.length} tasks. Removing history never changes
                    calendar events.
                  </p>
                </div>
                <button
                  className="button secondary"
                  onClick={() => void a.run("navigate", { page: "library" })}
                >
                  Manage history
                </button>
              </div>
              <div className="settings-row">
                <div>
                  <h3>Advanced</h3>
                  <p>Connection setup, storage and native preferences.</p>
                </div>
                <button
                  className="button secondary"
                  onClick={() => void a.run("advancedSettings")}
                >
                  Open
                </button>
              </div>
            </div>
          </section>
        )}
        {editingKey && (
          <Modal
            title="Save an OpenAI API key"
            onClose={() => {
              setEditingKey(false);
              setKey("");
            }}
          >
            <form
              onSubmit={async (e) => {
                e.preventDefault();
                if (await a.run("saveAPIKey", { key: key.trim() })) {
                  setKey("");
                  setEditingKey(false);
                }
              }}
            >
              <label>
                API key
                <input
                  autoFocus
                  type="password"
                  value={key}
                  onChange={(e) => setKey(e.target.value)}
                  autoComplete="off"
                  spellCheck={false}
                  required
                />
              </label>
              <p className="fine-print" style={{ marginTop: 12 }}>
                Stored in macOS Keychain. API usage is billed separately. Saving
                does not change your selected AI service.
              </p>
              <InlineError message={a.error} />
              <footer>
                <button
                  type="button"
                  className="button secondary"
                  onClick={() => {
                    setEditingKey(false);
                    setKey("");
                  }}
                >
                  Cancel
                </button>
                <button
                  className="button primary"
                  disabled={!key.trim() || a.busy}
                >
                  {a.busy && <Spinner />}Save key
                </button>
              </footer>
            </form>
          </Modal>
        )}
      </div>
    </div>
  );
}

const memoryKinds = ["preference", "fact", "person", "routine"] as const;
function MemoryRow({
  item,
  token,
  disabled,
}: {
  item: PersonalMemoryItem;
  token: string;
  disabled: boolean;
}) {
  const a = useAction();
  const [editing, setEditing] = useState(false);
  const [editAuthority, setEditAuthority] = useState({
    token,
    version: item.version,
  });
  const [text, setText] = useState(item.text);
  const [kind, setKind] = useState(item.kind);
  const pending = item.status === "pendingApproval";
  const run = (action: string, extra = {}) =>
    a.run(action, {
      token,
      memoryID: item.id,
      expectedVersion: item.version,
      ...extra,
    });
  return (
    <div className="personal-memory-row">
      {editing ? (
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            if (
              await a.run("editMemory", {
                token: editAuthority.token,
                memoryID: item.id,
                expectedVersion: editAuthority.version,
                text,
                kind,
              })
            )
              setEditing(false);
          }}
        >
          <label>
            Memory text
            <textarea
              aria-label="Memory text"
              maxLength={500}
              required
              value={text}
              onChange={(e) => setText(e.target.value)}
            />
          </label>
          <Select
            label="Memory kind"
            value={kind}
            onChange={(value) => setKind(value as typeof kind)}
          >
            {memoryKinds.map((k) => (
              <option key={k}>{k}</option>
            ))}
          </Select>
          <button className="button primary" disabled={a.busy || disabled}>
            Save memory
          </button>
          <button
            type="button"
            className="button secondary"
            onClick={() => setEditing(false)}
          >
            Cancel
          </button>
        </form>
      ) : (
        <>
          <p>{item.text}</p>
          {item.expiresAt && new Date(item.expiresAt) <= new Date() && (
            <Badge>Expired</Badge>
          )}
          <div className="personal-memory-actions">
            <button
              className="button secondary"
              disabled={a.busy || disabled}
              onClick={() => {
                setText(item.text);
                setKind(item.kind);
                setEditAuthority({ token, version: item.version });
                setEditing(true);
              }}
            >
              Edit
            </button>
            {pending ? (
              <>
                <button
                  className="button primary"
                  disabled={a.busy || disabled}
                  onClick={() => void run("approveMemory")}
                >
                  Approve
                </button>
                <button
                  className="button secondary"
                  disabled={a.busy || disabled}
                  onClick={() =>
                    void run("rejectMemory", { dontSuggestAgain: false })
                  }
                >
                  Reject
                </button>
                <button
                  className="button secondary"
                  disabled={a.busy || disabled}
                  onClick={() =>
                    void run("rejectMemory", { dontSuggestAgain: true })
                  }
                >
                  Don't suggest again
                </button>
              </>
            ) : (
              <button
                className="button secondary"
                disabled={a.busy || disabled}
                onClick={() => void run("forgetMemory")}
              >
                Forget
              </button>
            )}
          </div>
        </>
      )}
      <InlineError message={a.error} />
    </div>
  );
}
export function PersonalMemorySettings({ state }: { state: AppState }) {
  const memory = state.personalMemory;
  const a = useAction();
  const [text, setText] = useState("");
  const [kind, setKind] = useState<PersonalMemoryItem["kind"]>("preference");
  const [confirmClear, setConfirmClear] = useState(false);
  const disabled = !memory?.loaded || !!memory.error;
  return (
    <section aria-label="Personal memory">
      <h2 className="section-label">Memory</h2>
      <div className="card settings-card">
        <p className="fine-print">
          Personal memories stay on this Mac, separately for each account.
          Relevant memories are sent to your chosen AI service as context. They
          never authorize changes. Forgetting prevents the same text from being
          suggested again; source history is kept separately.
        </p>
        <InlineError message={memory?.error || ""} />
        {!memory?.loaded && !memory?.error && <p>Loading memories…</p>}
        {memory?.loaded && !memory.items.length && !memory.pending.length && (
          <p>No personal memories yet.</p>
        )}
        {memoryKinds.map(
          (k) =>
            memory?.items.some((i) => i.kind === k) && (
              <div key={k}>
                <h3>{k[0].toUpperCase() + k.slice(1)}</h3>
                {memory.items
                  .filter((i) => i.kind === k)
                  .map((i) => (
                    <MemoryRow
                      key={i.id}
                      item={i}
                      token={memory.token}
                      disabled={disabled}
                    />
                  ))}
              </div>
            ),
        )}
        {!!memory?.pending.length && (
          <div>
            <h3>Suggested memories</h3>
            {memory.pending.map((i) => (
              <MemoryRow
                key={i.id}
                item={i}
                token={memory.token}
                disabled={disabled}
              />
            ))}
          </div>
        )}
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            if (await a.run("addMemory", { token: memory?.token, text, kind }))
              setText("");
          }}
        >
          <label>
            New memory
            <textarea
              aria-label="New memory"
              required
              maxLength={500}
              value={text}
              disabled={disabled}
              onChange={(e) => setText(e.target.value)}
            />
          </label>
          <Select
            label="New memory kind"
            value={kind}
            disabled={disabled}
            onChange={(value) => setKind(value as typeof kind)}
          >
            {memoryKinds.map((k) => (
              <option key={k}>{k}</option>
            ))}
          </Select>
          <button
            className="button primary"
            disabled={disabled || a.busy || !text.trim()}
          >
            Add memory
          </button>
          <InlineError message={a.error} />
        </form>
        {!!memory && !!(memory.items.length + memory.pending.length) && (
          <>
            <label className="inline-check">
              <input
                type="checkbox"
                checked={confirmClear}
                onChange={(e) => setConfirmClear(e.target.checked)}
              />
              Confirm forgetting all personal memories
            </label>
            <button
              className="button secondary"
              disabled={disabled || !confirmClear || a.busy}
              onClick={async () => {
                if (
                  await a.run("clearMemory", {
                    token: memory.token,
                    confirmed: true,
                  })
                )
                  setConfirmClear(false);
              }}
            >
              Forget all memories
            </button>
          </>
        )}
      </div>
    </section>
  );
}

function VoiceSettings({ state }: { state: AppState }) {
  const v = state.voice;
  const a = useAction();
  const [model, setModel] = useState(v?.model || "");
  const [voice, setVoice] = useState(v?.voice || "marin");
  const [cap, setCap] = useState(String(v?.monthlyCap ?? 10));
  const [recording, setRecording] = useState(false);
  if (!v) return <p>Voice settings are available in the Mac app.</p>;
  return <section className="card settings-card voice-settings"><h2>Voice</h2>
    <p>Microphone audio and screen frames are sent to OpenAI. Voice uses paid OpenAI Realtime API billing and requires an OpenAI API key. ChatGPT plan billing does not cover voice. The estimate includes transcription.</p>
    <InlineError message={a.error || v.error} />
    <label>Voice shortcut <button className="button secondary" disabled={v.active} onClick={() => { setRecording(!recording); void a.run("voiceShortcutRecording", { token: v.token, enabled: !recording }); }} onKeyDown={e => {
      if (!recording) return;
      e.preventDefault();
      if (e.key === "Escape") { setRecording(false); void a.run("voiceShortcutRecording", { token: v.token, enabled: false }); return; }
      const codes: Record<string, number> = { KeyA: 0, KeyS: 1, KeyD: 2, KeyF: 3, KeyH: 4, KeyG: 5, KeyZ: 6, KeyX: 7, KeyC: 8, KeyV: 9, KeyB: 11, KeyQ: 12, KeyW: 13, KeyE: 14, KeyR: 15, KeyY: 16, KeyT: 17, KeyO: 31, KeyU: 32, KeyI: 34, KeyP: 35, KeyL: 37, KeyJ: 38, KeyK: 40, KeyN: 45, KeyM: 46 };
      const modifiers = (e.metaKey ? 256 : 0) | (e.shiftKey ? 512 : 0) | (e.altKey ? 2048 : 0) | (e.ctrlKey ? 4096 : 0);
      if (!(e.ctrlKey || e.metaKey) || codes[e.code] === undefined) return;
      const label = (e.ctrlKey ? "⌃" : "") + (e.altKey ? "⌥" : "") + (e.shiftKey ? "⇧" : "") + (e.metaKey ? "⌘" : "") + e.key.toUpperCase();
      void a.run("voiceShortcut", { token: v.token, keyCode: codes[e.code], modifiers, label }).finally(() => { void command({ action: "voiceShortcutRecording", token: v.token, enabled: false }).catch(() => {}); }); setRecording(false);
    }}>{recording ? "Press a modified letter…" : state.voiceShortcut || "⌃⇧V"}</button></label>
    <label>Model <input value={model} disabled={v.active} onChange={e => setModel(e.target.value)} /></label>
    <label>Voice <select value={voice} disabled={v.active} onChange={e => setVoice(e.target.value)}>{["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"].map(name => <option key={name}>{name}</option>)}</select></label>
    <label>Monthly cap (USD) <input type="number" min="0" max="10000" value={cap} disabled={v.active} onChange={e => setCap(e.target.value)} /></label>
    <button className="button primary" disabled={v.active || a.busy} onClick={() => void a.run("voiceSettings", { token: v.token, model, voice, cap: Number(cap) })}>Save voice settings</button>
    <p>Microphone: {v.permissions.microphone ? "Allowed" : "Check access"} <button onClick={() => void a.run("voiceMicrophoneSettings", { token: v.token })}>Open microphone settings</button></p>
    <p>Screen Recording: {v.permissions.screen ? "Allowed" : "Voice only until allowed"} <button onClick={() => void a.run("screenSettings")}>Set up Screen Recording</button></p>
  </section>;
}
