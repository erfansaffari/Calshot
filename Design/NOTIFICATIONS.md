# Notifications: event alerts, task reminders and the notch alert

Status: first implementation, 2026-11-17. Part of the proactive direction in [PERSONAL_AGENT_PLAN.md](PERSONAL_AGENT_PLAN.md).

## Two layers

| Layer | Where it lives | Who sees it |
| --- | --- | --- |
| **Event alerts** | On the event itself, in the calendar account (EventKit alarms, Google pop-up reminders, Outlook's reminder, iCloud VALARM) | Every device and calendar app, plus Calshot's notch on this Mac |
| **Task reminders** | On the task (`reminderMinutes`, `reminderTime`, `reminderDeviceID`), delivered by the Mac that set them | Calshot's notch while Calshot runs; a macOS notification (same chime) when it doesn't |

Calshot never invents an alert for an event it is not otherwise creating or changing, and never writes anything to show, snooze or dismiss an alert.

## Event alerts (synced)

- `EventDraft.alertMinutes` / `CalendarEventSnapshot.alertMinutes`: minutes before the start, sorted and unique, 0–40320, at most five (`EventAlerts`). nil on a draft keeps the provider's alerts; `[]` removes them. On an update they are written only when `alerts` is among the changed fields.
- EventKit replaces relative alarms and keeps fixed-date alarms set elsewhere. Google writes `reminders.overrides` (pop-up) and reads `useDefault` through the calendar's `defaultReminders` (timed events only); email reminders are not shown as Mac alerts. Outlook keeps one reminder, so the alert nearest the start wins. iCloud writes `VALARM` (`ACTION:DISPLAY`, relative `TRIGGER`); the ICS parser now ignores properties inside nested components, so an alarm's `DESCRIPTION` is never read or rewritten as the event's notes.
- Changing alerts is an ordinary event edit: `create_events` / `update_event` take `alerts`, the calendar grant field `alerts` covers it (Autonomy grants saved before this field are widened natively while Autonomy is on), the review row shows `Alerts: before → after`, the receipt keeps the prior alerts, and Undo restores them.
- People can set one alert by hand in Calendar's New event and Edit event forms (`Calendar default` / `Keep: …`, None, a lead time; all-day events offer "Day before at 9 AM" choices). The event details card lists current alerts.

## Agent decisions

Settings → Notifications → **Let Calshot choose alerts** (on by default) adds `Calshot chooses alerts: on.` to every request's native context. The prompt section ALERTS AND REMINDERS gives the defaults: 10 minutes for a one-off meeting or appointment, 5 with a video link, 30 when travel is involved, a day and an hour for high-stakes items; nothing new for all-day, holidays, focus blocks, free entries and routine repeating items. Tasks: at the due time for chores, an hour before for prepared work, a day before for important deadlines, the user's usual start of day (else 09:00) for date-only tasks that matter, none for trivial or undated tasks. A task reminder needs a due date: for "remind me at 8 tonight" on an undated task the agent sets the date and time from the user's words with a reminder at the due time, and asks only when no day or time was given. In the task editor, **Remind me** sits beside the due date (disabled with "Add a due date to set a reminder." until one is set). The user's words always win; a remembered preference overrides the defaults. Alerts never change or fill an event's date or time. Off: alerts and reminders only when asked.

Questions about upcoming reminders ("what's my earliest reminder?") use the read-only `upcoming_alerts` tool. Calshot computes every alert moment itself: event alerts (the start minus each alert on the event, deduplicated across calendars) and task reminders (with the device that delivers them), earliest first, from now up to 31 days ahead. The model never works these times out by hand.

## Calshot's alert on this Mac

- `CalshotAlertCenter` (native, read-only) plans from the user's own readable calendars (next 26 hours, every 5 minutes, on calendar/task changes, wake, clock and time-zone changes) and the task reminders this Mac delivers. One timer to the next alert. Delivered alerts are remembered for two days, so a relaunch never repeats one.
- After sleep or a locked screen: alerts within 10 minutes of their time, or for an event that hasn't been going for more than 5 minutes, still show; at most three, one at a time. A locked screen defers event alerts and leaves task reminders to macOS.
- Task reminders fire three seconds early in Calshot and withdraw the matching macOS notification, so a running Calshot shows only the notch. Calshot's own task-deadline calendar entries are skipped.
- The **notch alert** is drawn by SwiftUI in the notch panel, on any display: it grows out of the camera housing, or hangs from the top edge. Icon, title, a live "in 10 min · 3:00 PM · Room 4" line, Join (only for https links on known meeting hosts), Snooze (to one minute before an event that is still more than 90 seconds away, else 5 minutes; tasks an hour), dismiss, and a click opens Calendar or Tasks. Meetings with a link stay until acted on or five minutes after the start; other alerts leave after 8 seconds; hovering pauses. It never steals focus, never becomes the hover quick menu, and returns the notch to the voice island or its previous state. Reduce Motion and full-screen spaces follow the notch panel's existing behaviour.
- **Sound**: `Resources/CalshotAlert.wav`, a soft two-note chime generated by `script/generate_alert_sound.swift` (−14 dBFS, 1.25 s). The same file is the sound of task reminders macOS delivers. No sound and no speech while another app is using the microphone (a call).

## Spoken alerts (optional)

Settings → Notifications → **Say alerts out loud**, off by default. For events starting within 15 minutes and task reminders, up to three an hour, never during a call: an open voice session says it when idle; otherwise Calshot opens voice only when nothing would need the user first (signed in, AI consent, API key, billing notice acknowledged, under the monthly cap, microphone already allowed, no run, review or question pending). The alert goes in as native system context marked as untrusted data, with a response that cannot call tools, so an announcement can never change anything. Push-to-talk means nothing is heard unless the user holds the voice key to answer ("push it 15 minutes"), which is then an ordinary spoken request under Autonomy. An unanswered proactive session ends after 20 seconds of silence.

## Settings → Notifications

Calshot alerts, Sound (with Preview of a fictional sample), Say alerts out loud, Let Calshot choose alerts, macOS permission for reminders while Calshot is closed (Allow / Open System Settings), a note that event alerts sync to the account (turn off Calendar notifications in System Settings to hear only Calshot), and the next 24 hours of alerts with read errors beside them and Try again. Every choice is device-local and never syncs.

## Verification

- Native: `Tests/CalshotAlertTests.swift` (alert bounds and labels, iCalendar triggers, iCloud alarm preservation, Google/Outlook bodies and snapshots, agent mapping and undo fields, tool schema, planner dedupe/catch-up/join links/countdown, task reminder choices, preferences, spoken alert with tool-free response). Full native suite.
- WebUI: `WebUI/tests/notifications.test.tsx`; browser fixtures `?preview=1&scenario=notifications`, `notifications-empty`, `notifications-error`, `notifications-voice`.
- Visual: `--alert-preview` (DEBUG) shows a fictional sample alert in the notch.

## Known limits

- Undo restores alert minutes, not provider-specific form: a Google event that used the calendar default comes back with the same minutes as explicit pop-up alerts, and Google email reminders on an event are replaced when Calshot changes its alerts.
- Outlook keeps one reminder; Calshot keeps the one nearest the start.
- Task sync needs `supabase/migrations/20261117120000_task_reminder_lead_times.sql` on the server: before it, the server accepts only At due time, 1 hour and 1 day before, and any other lead time stops the whole task list from syncing ("The sync server doesn’t accept this task reminder yet"). Macs on builds before this feature also reject the new lead times when reading synced tasks. `testTaskSyncServerAcceptsEveryReminderChoice` keeps the server list equal to `CalshotTask.reminderChoices`.
- macOS Calendar and Google still send their own notifications; Calshot can't silence other apps.
- Microphone activity is a hint for "on a call"; it can't detect screen sharing.

## Deferred

Morning brief, travel-time ("leave now") alerts, per-calendar mute, learning lead times from snoozes, a Focus filter, and spoken confirmation of the follow-up offer.
