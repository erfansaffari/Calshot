import { useState } from "react";
import { command } from "../bridge";
import type { Proposal } from "../types";
import { Modal, Spinner } from "./ui";
function local(value?: string, zone?: string) {
  if (!value) return "";
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: zone || undefined,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(value));
  const v = (name: string) => parts.find((p) => p.type === name)?.value || "";
  return (
    v("year") +
    "-" +
    v("month") +
    "-" +
    v("day") +
    "T" +
    v("hour") +
    ":" +
    v("minute")
  );
}
export function ProposalEditor({
  item,
  token,
  onClose,
  suspended = false,
}: {
  item: Proposal;
  token: string;
  onClose: () => void;
  suspended?: boolean;
}) {
  const d = item.draft;
  const [form, setForm] = useState({
    title: d.title,
    start: local(d.startDate, d.timeZoneIdentifier),
    end: local(d.endDate, d.timeZoneIdentifier),
    allDay: d.isAllDay,
    timeZone:
      d.timeZoneIdentifier || Intl.DateTimeFormat().resolvedOptions().timeZone,
    location: d.location || "",
    url: d.url || "",
    notes: d.notes || "",
  });
  const [imageFailed, setImageFailed] = useState(false);
  const [saving, setSaving] = useState(false),
    [error, setError] = useState("");
  const change = (key: string, value: unknown) =>
    setForm({ ...form, [key]: value });
  return (
    <Modal title="Review event details" onClose={onClose} suspended={suspended}>
      <form
        className="event-form"
        onSubmit={async (e) => {
          e.preventDefault();
          setSaving(true);
          setError("");
          try {
            await command({
              action: "editProposal",
              proposalID: item.id,
              token,
              fields: form,
            });
            onClose();
          } catch (err) {
            setError((err as Error).message);
          } finally {
            setSaving(false);
          }
        }}
      >
        <label>
          Event title
          <input
            value={form.title}
            onChange={(e) => change("title", e.target.value)}
            required
            autoFocus
          />
        </label>
        <div className="form-grid">
          <label>
            Starts
            <input
              type="datetime-local"
              value={form.start}
              onChange={(e) => change("start", e.target.value)}
              required
            />
          </label>
          <label>
            Ends
            <input
              type="datetime-local"
              value={form.end}
              onChange={(e) => change("end", e.target.value)}
              required
            />
          </label>
        </div>
        <label className="inline-check">
          <input
            type="checkbox"
            disabled={Boolean(d.taskID)}
            checked={form.allDay}
            onChange={(e) => change("allDay", e.target.checked)}
          />{" "}
          {d.taskID ? "All-day deadline · does not reserve work time" : "All-day event"}
        </label>
        {form.allDay && (
          <p className="fine-print">
            {d.taskID ? "This deadline covers one day. Edit its exact due time from the Tasks page." : "For all-day events, the end date is the first day after the event. Times are saved at midnight."}
          </p>
        )}
        <label>
          Time zone
          <input
            value={form.timeZone}
            onChange={(e) => change("timeZone", e.target.value)}
            required
          />
        </label>
        <div className="form-grid">
          <label>
            Location
            <input
              value={form.location}
              onChange={(e) => change("location", e.target.value)}
            />
          </label>
          <label>
            Link
            <input
              type="url"
              value={form.url}
              onChange={(e) => change("url", e.target.value)}
            />
          </label>
        </div>
        <label>
          Notes
          <textarea
            value={form.notes}
            onChange={(e) => change("notes", e.target.value)}
            rows={3}
          />
        </label>
        {!!d.sourceText && (
          <details>
            <summary>View source evidence</summary>
            {item.sourceImageURL && !imageFailed && (
              <div className="evidence-frame">
                <div>
                  <img
                    src={item.sourceImageURL}
                    alt="Original screenshot for this event"
                    onError={() => setImageFailed(true)}
                  />
                  {d.sourceRegion && (
                    <span
                      aria-label="Matched source region"
                      style={{
                        left: d.sourceRegion.x * 100 + "%",
                        top: d.sourceRegion.y * 100 + "%",
                        width: d.sourceRegion.width * 100 + "%",
                        height: d.sourceRegion.height * 100 + "%",
                      }}
                    />
                  )}
                </div>
              </div>
            )}
            {imageFailed && (
              <p className="fine-print">
                The source image is unavailable. The recognized evidence is
                shown below.
              </p>
            )}
            <p className="source-text">{d.sourceText}</p>
          </details>
        )}
        {error && (
          <p className="error-text" role="alert">
            {error}
          </p>
        )}
        <p className="fine-print">
          Saving confirms the displayed date, year, time and time zone. Calendar
          changes still need approval.
        </p>
        <footer>
          <button type="button" className="button secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="button primary" disabled={saving}>
            {saving && <Spinner />}Save reviewed details
          </button>
        </footer>
      </form>
    </Modal>
  );
}
