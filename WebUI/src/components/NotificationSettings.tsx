import { useAction } from "../useAction";
import type { AppState, NotificationsState, UpcomingAlert } from "../types";
import { InlineError, Spinner } from "./ui";
import { alertLeadLabel } from "../alertPresentation";

type Key = "enabled" | "sound" | "spoken" | "smartAlerts";

function Switch({ label, on, disabled, onChange }: { label: string; on: boolean; disabled?: boolean; onChange: (next: boolean) => void }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} className={"switch" + (on ? " is-on" : "")}
      disabled={disabled} onClick={() => onChange(!on)}><i /></button>
  );
}

function UpcomingRow({ alert }: { alert: UpcomingAlert }) {
  const start = new Date(alert.start), fire = new Date(alert.fireAt);
  const time = (d: Date) => d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const day = (d: Date) => (d.toDateString() === new Date().toDateString() ? "" : d.toLocaleDateString([], { weekday: "short" }) + " ");
  return (
    <li className="upcoming-alert">
      <span className="upcoming-alert-time">{day(fire)}{time(fire)}</span>
      <span className="upcoming-alert-title">{alert.title}</span>
      <span className="upcoming-alert-detail">
        {alert.snoozed ? "Snoozed" : alertLeadLabel(alert.lead, alert.kind)}
        {alert.kind === "task" ? " · Task" : ` · ${day(start)}${time(start)}`}
        {alert.join ? " · Meeting link" : ""}
      </span>
    </li>
  );
}

export function NotificationSettings({ state }: { state: AppState }) {
  const a = useAction();
  const n: NotificationsState | undefined = state.notifications;
  if (!n) return null;
  const set = (key: Key, value: boolean) => void a.run("notificationPreferences", { [key]: value });
  const permission = n.systemPermission;
  return (
    <section aria-labelledby="notifications-heading">
      <h2 className="section-label" id="notifications-heading">Alerts {a.busy && <Spinner />}</h2>
      <div className="card settings-card notification-settings">
        <div className="settings-row">
          <div>
            <h3>Calshot alerts</h3>
            <p>Event alerts and task reminders appear at the top of your screen, with Join for meetings and Snooze.</p>
          </div>
          <Switch label="Calshot alerts" on={n.enabled} disabled={a.busy} onChange={(v) => set("enabled", v)} />
        </div>
        <div className="settings-row">
          <div>
            <h3>Sound</h3>
            <p>A soft chime with each alert. Calshot stays silent while another app is using the microphone, such as a call.</p>
          </div>
          <div className="settings-row-actions">
            <button type="button" className="text-button" disabled={a.busy || !n.enabled} onClick={() => void a.run("previewAlert")}>Preview</button>
            <Switch label="Alert sound" on={n.sound} disabled={a.busy || !n.enabled} onChange={(v) => set("sound", v)} />
          </div>
        </div>
        <div className="settings-row">
          <div>
            <h3>Say alerts out loud</h3>
            <p>
              Calshot’s voice tells you when a meeting is about to start or a reminder is due. Answer by holding the voice key, for
              example “push it 15 minutes”; nothing is heard unless you do. Up to three an hour, never during a call, and it uses
              your voice minutes.
            </p>
            {n.spoken && !n.voiceReady && <p role="status">Voice isn’t ready yet, so alerts show without speaking. Finish setup in Settings → Voice.</p>}
          </div>
          <Switch label="Say alerts out loud" on={n.spoken} disabled={a.busy || !n.enabled} onChange={(v) => set("spoken", v)} />
        </div>
        <div className="settings-row">
          <div>
            <h3>Let Calshot choose alerts</h3>
            <p>
              When you add something without saying, Calshot picks a sensible alert: 10 minutes before a meeting, a day and an hour
              before an exam, none for all-day events. You can always say what you want instead.
            </p>
          </div>
          <Switch label="Let Calshot choose alerts" on={n.smartAlerts} disabled={a.busy} onChange={(v) => set("smartAlerts", v)} />
        </div>
        <div className="settings-row">
          <div>
            <h3>Reminders when Calshot is closed</h3>
            <p>
              {permission === "allowed" ? "On. macOS delivers task reminders even when Calshot isn’t running."
                : permission === "denied" ? "Off. macOS won’t deliver task reminders while Calshot is closed. Allow Calshot in System Settings → Notifications."
                : "macOS needs your permission to deliver task reminders while Calshot is closed."}
            </p>
          </div>
          {permission === "denied"
            ? <button type="button" className="button secondary" onClick={() => void a.run("notificationSystemSettings")}>Open System Settings</button>
            : permission !== "allowed" && <button type="button" className="button secondary" disabled={a.busy} onClick={() => void a.run("requestNotificationPermission")}>Allow</button>}
        </div>
        <p className="fine-print">
          Event alerts are saved on the event in your calendar account, so your phone and other calendar apps show them too. To hear
          only Calshot on this Mac, turn off Calendar notifications in System Settings → Notifications.
        </p>
        <InlineError message={a.error} />
      </div>

      <h2 className="section-label">Next 24 hours</h2>
      <div className="card settings-card">
        <InlineError message={n.error || ""}>
          <button type="button" className="text-button" onClick={() => void a.run("refreshAlerts")}>Try again</button>
        </InlineError>
        {!n.enabled ? <p>Calshot alerts are off.</p>
          : n.upcoming.length === 0 ? <p>{n.lastRefresh ? "No alerts in the next 24 hours." : "Checking your calendars…"}</p>
          : <ul className="upcoming-alerts" aria-label="Upcoming alerts">{n.upcoming.map((alert) => <UpcomingRow key={alert.id} alert={alert} />)}</ul>}
      </div>
    </section>
  );
}
