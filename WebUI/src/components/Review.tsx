import { useState } from "react";
import {
  ArrowRight,
  Check,
  CheckCircle2,
  Pencil,
  Info,
  AlertTriangle,
} from "lucide-react";
import type { AppState, Proposal } from "../types";
import { command } from "../bridge";
import {
  Badge,
  CheckBox,
  InlineError,
  Select,
  formatDate,
  timeRange,
  Spinner,
} from "./ui";
import { ProposalEditor } from "./ProposalEditor";
export function eventWhen(item: Proposal) {
  const d = item.draft;
  return (
    formatDate(d.startDate, d.timeZoneIdentifier, {
      weekday: "short",
      year: "numeric",
    }) +
    " · " +
    timeRange(d.startDate, d.endDate, d.timeZoneIdentifier, d.isAllDay)
  );
}
export function Review({ state }: { state: AppState }) {
  const [editing, setEditing] = useState<Proposal>(),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [compare, setCompare] = useState<string>();
  const rows = state.proposals.filter((p) => p.inScope && !p.isFinished),
    finished = state.proposals.filter((p) => p.isFinished);
  const selected = rows.filter((p) => p.isSelected),
    move = rows.length > 0 && rows.every((p) => p.operation === "move");
  const retryOnly =
    selected.length > 0 && selected.every((item) => item.state === "failed");
  const failedCount = rows.filter((item) => item.state === "failed").length;
  const calendars = state.calendars.filter(
    (c) => !c.isReadOnly && !c.unavailable,
  );
  const destination = calendars.find((c) => c.id === state.selectedCalendarID);
  const kinds = [
    ["create", "Add"],
    ["update", "Change"],
    ["delete", "Remove"],
    ["move", "Move"],
  ]
    .map(([kind, label]) => ({
      kind,
      label,
      count: selected.filter((p) => p.operation === kind).length,
    }))
    .filter((k) => k.count);
  const run = async (action: string, extra: Record<string, unknown> = {}) => {
    setError("");
    setBusy(true);
    try {
      await command({ action, token: state.approvalToken, ...extra });
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  if (!rows.length && !finished.length) return null;
  return (
    <>
      {!!rows.length && (
        <section className="card review" aria-label="Review calendar changes">
          <header className="card-header">
            <div>
              <h3>
                {failedCount
                  ? failedCount + " events didn't save"
                  : move
                    ? "Move " + rows.length + " events"
                    : rows.length +
                      " calendar " +
                      (rows.length === 1 ? "action" : "actions")}
              </h3>
              <small>
                {state.saving
                  ? "Saving approved changes…"
                  : failedCount
                    ? "Completed events stay saved. Review what to retry."
                    : "Nothing changes until you approve"}
              </small>
            </div>
            {rows.some((p) => p.operation === "create") && (
              <Select
                label="Destination calendar"
                value={state.selectedCalendarID}
                onChange={(calendarID) =>
                  void run("selectCalendar", { calendarID })
                }
                disabled={state.saving || busy}
              >
                {!destination && <option value="">Choose a calendar</option>}
                {calendars.map((c) => (
                  <option value={c.id} key={c.id}>
                    {c.title} · {c.provider === "apple" ? "iCloud" : c.provider}
                  </option>
                ))}
              </Select>
            )}
          </header>
          {move && (
            <div className="transfer-path">
              <div>
                <strong>
                  {rows[0].sourceCalendarName || "Source calendar"}
                </strong>
                <small>From</small>
              </div>
              <ArrowRight size={18} />
              <div>
                <strong>
                  {rows[0].targetCalendarName ||
                    destination?.title ||
                    "Destination"}
                </strong>
                <small>To</small>
              </div>
            </div>
          )}
          <div className="review-list">
            {rows.map((item) => (
              <div key={item.id} className="proposal">
                <CheckBox
                  checked={item.isSelected}
                  disabled={!item.canSelect || busy || state.saving}
                  label={"Include " + item.draft.title}
                  onChange={(selected) =>
                    void run("selectProposal", {
                      proposalID: item.id,
                      selected,
                    })
                  }
                />
                <div className="proposal-body">
                  {(item.operation !== "create" || item.state === "failed") && (
                    <Badge tone={item.state === "failed" ? "error" : "neutral"}>
                      {item.state === "failed"
                        ? "Failed"
                        : {
                            update: "Change",
                            delete: "Remove",
                            move: "Move",
                            create: "Add",
                          }[item.operation]}
                    </Badge>
                  )}
                  <h3>{item.draft.title || "Untitled event"}</h3>
                  <div className="event-time">{eventWhen(item)}</div>
                  {item.operation === "move" && (
                    <p className="event-time">
                      {item.moveCopyReceipt
                        ? "Reuse verified copy, then remove original"
                        : "Copy, verify, then remove original"}
                    </p>
                  )}
                  {item.operation === "delete" && (
                    <p className="row-issue">
                      {item.targetCalendarName || item.sourceCalendarName} ·
                      Select to remove this event
                    </p>
                  )}
                  {item.operation === "update" && item.before && (
                    <div className="before-after">
                      <div>
                        <small>Current</small>
                        {item.before.title}
                        <br />
                        {formatDate(
                          item.before.startDate,
                          item.before.timeZoneIdentifier,
                        )}{" "}
                        ·{" "}
                        {timeRange(
                          item.before.startDate,
                          item.before.endDate,
                          item.before.timeZoneIdentifier,
                          item.before.isAllDay,
                        )}
                      </div>
                      <div>
                        <small>Proposed</small>
                        {item.draft.title}
                        <br />
                        {eventWhen(item)}
                      </div>
                    </div>
                  )}
                  {item.issues.map((issue) => (
                    <p className="row-issue" key={issue}>
                      {issue}
                    </p>
                  ))}
                  {!!item.duplicateIdentifiers.length &&
                    !item.allowDuplicate && (
                      <div className="row-issue">
                        Possible duplicate already on this calendar.{" "}
                        <button
                          className="text-button"
                          disabled={busy || state.saving}
                          onClick={async () => {
                            if (compare === item.id) {
                              setCompare(undefined);
                              return;
                            }
                            setCompare(item.id);
                            await run("compareDuplicate", {
                              proposalID: item.id,
                            });
                          }}
                        >
                          Compare
                        </button>
                      </div>
                    )}
                  {compare === item.id && (
                    <div className="transfer-note">
                      {state.duplicateComparisons?.[item.id]?.map(
                        (draft, index) => (
                          <div className="before-after" key={index}>
                            <div>
                              <small>Already in calendar</small>
                              <strong>{draft.title}</strong>
                              <br />
                              {formatDate(
                                draft.startDate,
                                draft.timeZoneIdentifier,
                              )}{" "}
                              ·{" "}
                              {timeRange(
                                draft.startDate,
                                draft.endDate,
                                draft.timeZoneIdentifier,
                                draft.isAllDay,
                              )}
                              {draft.location && <p>{draft.location}</p>}
                            </div>
                            <div>
                              <small>Proposed</small>
                              <strong>{item.draft.title}</strong>
                              <br />
                              {eventWhen(item)}
                            </div>
                          </div>
                        ),
                      )}
                      <p>
                        {item.draft.title} · {eventWhen(item)}
                      </p>
                      <p>
                        A title and time match was found. Keep it unchecked to
                        preserve the existing event, or deliberately add another
                        copy.
                      </p>
                      <button
                        className="text-button"
                        disabled={busy}
                        onClick={() =>
                          void run("allowDuplicate", { proposalID: item.id })
                        }
                      >
                        Add another copy anyway
                      </button>
                    </div>
                  )}
                  {item.error && (
                    <p className="row-error" role="alert">
                      {item.moveCopyReceipt
                        ? "Copy exists in the destination; the original may still remain. "
                        : ""}
                      {item.error}
                    </p>
                  )}
                </div>
                {item.operation !== "move" && item.operation !== "delete" && (
                  <button
                    className="icon-button"
                    disabled={state.saving || busy}
                    aria-label={"Edit " + item.draft.title}
                    onClick={() => setEditing(item)}
                  >
                    <Pencil size={14} />
                  </button>
                )}
              </div>
            ))}
          </div>
          {move && (
            <p className="transfer-note">
              <Info size={12} /> One approval covers the selected transfers. If
              a copy fails, its original stays untouched.
            </p>
          )}
          <div
            style={{ padding: error || state.reviewMessage ? "10px 14px" : 0 }}
          >
            <InlineError message={error} />
            {state.reviewMessage && (
              <p className="fine-print" role="status">
                {state.reviewMessage}
              </p>
            )}
          </div>
          <footer className="review-footer">
            <small>
              {kinds.length
                ? kinds.map((k) => k.label + " " + k.count).join(" · ")
                : "Select ready events"}
              <br />
              {selected.length} of {rows.length} selected
            </small>
            <button
              className="button secondary"
              disabled={state.saving || busy}
              onClick={() => void run("skipApproval")}
            >
              Skip
            </button>
            <button
              className="button primary"
              disabled={
                !state.canApprove || !destination || state.saving || busy
              }
              onClick={() => void run("approve")}
            >
              {state.saving || busy ? <Spinner /> : <Check size={14} />}{" "}
              {state.saving
                ? "Saving…"
                : retryOnly
                  ? "Retry " + selected.length + " failed"
                  : (move
                      ? "Move"
                      : kinds.length === 1
                        ? kinds[0].label
                        : "Approve") +
                    " " +
                    selected.length +
                    (kinds.length === 1 &&
                    kinds[0].kind === "create" &&
                    destination
                      ? " to " + destination.title
                      : "")}
            </button>
          </footer>
        </section>
      )}
      {!!finished.length && (
        <section className="card" aria-label="Confirmed calendar results">
          <header className="receipt-title">
            <CheckCircle2 size={17} />
            <h3>
              {finished.length} {finished.length === 1 ? "change" : "changes"}{" "}
              confirmed
            </h3>
          </header>
          <details style={{ padding: "12px 16px" }}>
            <summary>Show completed events</summary>
            {finished.map((item) => (
              <div className="proposal" key={item.id}>
                <Badge tone="success">{item.status}</Badge>
                <div className="proposal-body">
                  <h3>{item.draft.title}</h3>
                  <p className="event-time">
                    {eventWhen(item)} ·{" "}
                    {item.receipt?.calendarName || item.targetCalendarName}
                  </p>
                </div>
              </div>
            ))}
          </details>
        </section>
      )}
      {editing && (
        <ProposalEditor
          key={editing.id}
          item={editing}
          token={state.approvalToken}
          onClose={() => setEditing(undefined)}
        />
      )}
    </>
  );
}
