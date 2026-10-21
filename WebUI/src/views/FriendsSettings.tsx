import { useEffect, useState } from "react";
import {
  Users,
  UserPlus,
  RefreshCw,
  ShieldCheck,
  CalendarDays,
} from "lucide-react";
import type { AppState, CalendarShare, SharingPermission } from "../types";
import {
  Badge,
  Empty,
  InlineError,
  Modal,
  Select,
  Spinner,
  formatDate,
} from "../components/ui";

const labels: Record<SharingPermission, string> = {
  busy: "Free/busy only",
  titles: "Event titles & times",
  details: "Full event details",
};
const descriptions: Record<SharingPermission, string> = {
  busy: "Your friend sees when you’re busy. Event titles, locations and notes stay hidden.",
  titles:
    "Your friend sees event titles and times. Locations, notes and links stay hidden.",
  details: "Your friend sees titles, times, locations, notes and event links.",
};
type Action = (
  action: string,
  extra?: Record<string, unknown>,
) => Promise<void>;

export function FriendsSettings({
  state,
  onAction,
}: {
  state: AppState;
  onAction: Action;
}) {
  const sharing = state.sharing;
  const [email, setEmail] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [permission, setPermission] = useState<SharingPermission>("titles");
  const [busy, setBusy] = useState("");
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [notice, setNotice] = useState("");
  const [stopping, setStopping] = useState<string>();
  const run = async (
    key: string,
    action: string,
    extra: Record<string, unknown> = {},
  ) => {
    if (busy) return false;
    setBusy(key);
    setErrors((old) => ({ ...old, [key]: "" }));
    try {
      await onAction(action, { ...extra, sharingToken: sharing?.token });
      return true;
    } catch (error) {
      setErrors((old) => ({ ...old, [key]: (error as Error).message }));
      return false;
    } finally {
      setBusy("");
    }
  };
  useEffect(() => {
    if (!sharing?.loaded && !sharing?.busy)
      void run("refresh", "refreshSharing");
  }, []);
  const locked = Boolean(busy || sharing?.busy);
  const outgoing = sharing?.shares.filter((s) => s.outgoing) || [];
  const incoming = sharing?.shares.filter((s) => !s.outgoing) || [];
  const requests = incoming.filter((s) => s.status === "pending");
  const friends = incoming.filter((s) => s.status === "accepted");
  const source = sharing?.sources.find((s) => s.id === stopping);
  return (
    <div className="friends-settings">
      <section className="sharing-intro">
        <div className="sharing-intro-icon">
          <Users size={23} />
        </div>
        <div>
          <h2>Your calendars, your circle</h2>
          <p>
            Share with people you choose. Ask Calshot about the calendars they
            share back.
          </p>
        </div>
        <button
          className="button secondary"
          disabled={locked}
          onClick={() => void run("refresh", "refreshSharing")}
        >
          {busy === "refresh" || sharing?.busy ? (
            <Spinner />
          ) : (
            <RefreshCw size={14} />
          )}{" "}
          Refresh
        </button>
      </section>
      <InlineError message={sharing?.error || errors.refresh} />
      {!sharing?.loaded ? (
        <div className="card sharing-loading" role="status">
          {locked ? (
            <>
              <Spinner /> Checking sharing and requests…
            </>
          ) : (
            "Sharing hasn’t loaded. Refresh to try again."
          )}
        </div>
      ) : (
        <>
          {!!requests.length && (
            <section aria-label="Sharing requests">
              <h2 className="section-label">
                Requests for you <Badge>{requests.length}</Badge>
              </h2>
              <div className="sharing-list">
                {requests.map((share) => (
                  <ShareCard
                    key={share.id}
                    share={share}
                    state={state}
                    locked={locked}
                    error={errors[share.id]}
                    onAction={onAction}
                    run={(action, extra) => run(share.id, action, extra)}
                  />
                ))}
              </div>
            </section>
          )}
          <section aria-label="Share calendars with a friend">
            <h2 className="section-label">Share with a friend</h2>
            <div className="card settings-card">
              {state.native ? (
                <form
                  className="sharing-form"
                  onSubmit={async (event) => {
                    event.preventDefault();
                    setNotice("");
                    if (
                      await run("request", "requestCalendarShare", {
                        email: email.trim(),
                        calendarIDs: selected,
                        permission,
                      })
                    ) {
                      setNotice(
                        `Request sent to ${email.trim()}. They’ll see it in Friends & sharing.`,
                      );
                      setEmail("");
                      setSelected([]);
                    }
                  }}
                >
                  <label className="field">
                    Their Calshot account email
                    <input
                      type="email"
                      required
                      maxLength={254}
                      autoComplete="off"
                      value={email}
                      onChange={(event) => setEmail(event.target.value)}
                      placeholder="friend@example.com"
                      disabled={locked}
                    />
                  </label>
                  <fieldset className="sharing-calendars" disabled={locked}>
                    <legend>Choose calendars</legend>
                    <p className="fine-print">
                      Only selected calendars upload a sharing copy. Nothing is
                      shared until your friend accepts.
                    </p>
                    <div className="sharing-calendar-choices">
                      {state.calendars
                        .filter((c) => !c.unavailable)
                        .map((calendar) => (
                          <label key={calendar.id}>
                            <input
                              type="checkbox"
                              checked={selected.includes(calendar.id)}
                              disabled={
                                locked ||
                                (!selected.includes(calendar.id) &&
                                  selected.length >= 20)
                              }
                              onChange={(event) =>
                                setSelected((old) =>
                                  event.target.checked
                                    ? [...old, calendar.id]
                                    : old.filter((id) => id !== calendar.id),
                                )
                              }
                            />
                            <CalendarDays size={15} />
                            <span>
                              {calendar.title}
                              <small>
                                {calendar.sourceName}
                                {calendar.isReadOnly
                                  ? " · Read-only source"
                                  : ""}
                              </small>
                            </span>
                          </label>
                        ))}
                    </div>
                    {!state.calendars.some((c) => !c.unavailable) && (
                      <p className="fine-print">
                        Connect a calendar in Calendar accounts first.
                      </p>
                    )}
                  </fieldset>
                  <div className="sharing-access">
                    <Select
                      label="Friend access"
                      value={permission}
                      onChange={(value) =>
                        setPermission(value as SharingPermission)
                      }
                      disabled={locked}
                    >
                      {Object.entries(labels).map(([value, label]) => (
                        <option key={value} value={value}>
                          {label}
                        </option>
                      ))}
                    </Select>
                    <p className="fine-print">
                      {descriptions[permission]} They can ask their agent about
                      this data, but can’t change your events.
                    </p>
                  </div>
                  <InlineError message={errors.request} />
                  {notice && (
                    <p className="sharing-success" role="status">
                      {notice}
                    </p>
                  )}
                  <div className="sharing-form-footer">
                    <p className="fine-print">
                      Both people need a verified Calshot account. Requests
                      expire after 7 days.
                    </p>
                    <button
                      className="button primary"
                      type="submit"
                      disabled={
                        locked ||
                        !email.trim() ||
                        !selected.length ||
                        state.running ||
                        state.saving ||
                        state.isCapturing ||
                        state.isRecognizing
                      }
                    >
                      {busy === "request" ? (
                        <Spinner />
                      ) : (
                        <UserPlus size={15} />
                      )}{" "}
                      Send sharing request
                    </button>
                  </div>
                </form>
              ) : (
                <>
                  <p>
                    Choose and publish calendars in the Mac app. You can accept
                    requests and manage existing access here.
                  </p>
                  <a className="button secondary" href="calshot://">
                    Open Mac app
                  </a>
                </>
              )}
            </div>
          </section>
          <section aria-label="Calendars shared with you">
            <h2 className="section-label">Shared with you</h2>
            {!friends.length ? (
              <Empty icon={<Users size={23} />} title="A little more in sync">
                When a friend shares back, their calendars appear here and in
                Calendar. Sharing yours doesn’t give you access to theirs.
              </Empty>
            ) : (
              <div className="sharing-list">
                {friends.map((share) => (
                  <ShareCard
                    key={share.id}
                    share={share}
                    state={state}
                    locked={locked}
                    error={errors[share.id]}
                    onAction={onAction}
                    run={(action, extra) => run(share.id, action, extra)}
                  />
                ))}
              </div>
            )}
          </section>
          {!!outgoing.length && (
            <section aria-label="Calendars you share">
              <h2 className="section-label">You share</h2>
              <div className="sharing-list">
                {outgoing.map((share) => (
                  <ShareCard
                    key={share.id}
                    share={share}
                    state={state}
                    locked={locked}
                    error={errors[share.id]}
                    onAction={onAction}
                    run={(action, extra) => run(share.id, action, extra)}
                  />
                ))}
              </div>
            </section>
          )}
          {!!sharing.sources.filter((s) => !s.withdrawn).length &&
            state.native && (
              <section aria-label="Published calendar copies">
                <h2 className="section-label">Sharing sync</h2>
                <div className="card settings-card">
                  <div className="settings-row">
                    <div>
                      <h3>Keep your circle up to date</h3>
                      <p>
                        Sharing copies cover the past 7 and next 55 days.
                        Updates require the source Mac to be running. A copy
                        older than 15 minutes is marked out of date.
                      </p>
                    </div>
                    <button
                      className="button secondary"
                      disabled={locked || state.running || state.saving}
                      onClick={() => void run("sync", "syncSharing")}
                    >
                      Sync now
                    </button>
                  </div>
                  <InlineError message={errors.sync} />
                  {sharing.sources
                    .filter((s) => !s.withdrawn)
                    .map((calendar) => (
                      <div key={calendar.id} className="sharing-source">
                        <div className="settings-row">
                          <div>
                            <h3>{calendar.name}</h3>
                            <p>
                              Last synced{" "}
                              {formatDate(calendar.syncedAt, undefined, {
                                hour: "numeric",
                                minute: "2-digit",
                              })}
                            </p>
                            <small>
                              Source:{" "}
                              {state.accountSync?.devices[
                                calendar.sourceKey.split(":")[0]
                              ]?.name || "Original Mac"}{" "}
                              · {formatDate(calendar.coverageStart)} –{" "}
                              {formatDate(calendar.coverageEnd)}
                            </small>
                          </div>
                          <button
                            className="text-button danger"
                            disabled={locked}
                            onClick={() => setStopping(calendar.id)}
                          >
                            Stop publishing
                          </button>
                        </div>
                        <InlineError
                          message={calendar.error || errors[calendar.id]}
                        />
                      </div>
                    ))}
                </div>
              </section>
            )}
          <p className="sharing-privacy fine-print">
            <ShieldCheck size={15} /> Access is read-only and checked for every
            calendar read. Stop sharing removes future access; previous answers
            may remain in conversation history.
          </p>
        </>
      )}
      {source && (
        <Modal
          title={`Stop publishing ${source.name}?`}
          onClose={() => !locked && setStopping(undefined)}
        >
          <p>
            This removes the sharing copy and access for everyone who received
            this calendar. Your original events and private web sync stay
            unchanged.
          </p>
          <InlineError message={errors[source.id]} />
          <footer>
            <button
              className="button secondary"
              disabled={locked}
              onClick={() => setStopping(undefined)}
            >
              Keep sharing
            </button>
            <button
              className="button secondary danger"
              disabled={locked}
              onClick={async () => {
                if (
                  await run(source.id, "withdrawSharingCalendar", {
                    calendarID: source.id,
                  })
                )
                  setStopping(undefined);
              }}
            >
              Stop publishing
            </button>
          </footer>
        </Modal>
      )}
    </div>
  );
}
function ShareCard({
  share,
  state,
  locked,
  error,
  run,
  onAction,
}: {
  share: CalendarShare;
  state: AppState;
  locked: boolean;
  error?: string;
  run: (action: string, extra: Record<string, unknown>) => Promise<boolean>;
  onAction: Action;
}) {
  const [permission, setPermission] = useState<SharingPermission>(
    share.permission,
  );
  useEffect(() => setPermission(share.permission), [share.permission]);
  const pending = share.status === "pending",
    expired = share.status === "expired";
  const change = (stop: boolean) =>
    run("manageCalendarShare", {
      requestID: share.id,
      permission: stop ? share.permission : permission,
      expectedPermission: share.permission,
      stop,
    });
  return (
    <article className="card sharing-person">
      <div className="sharing-person-heading">
        <span className="sharing-avatar">
          <Users size={18} />
        </span>
        <div>
          <h3>{share.personName}</h3>
          {share.email && share.email !== share.personName && (
            <p className="fine-print">{share.email}</p>
          )}
        </div>
        <Badge tone={expired ? "warning" : pending ? "neutral" : "success"}>
          {expired ? "Expired" : pending ? "Request pending" : "Sharing active"}
        </Badge>
      </div>
      <div className="sharing-calendar-tags">
        {share.calendars.map((c) => (
          <span key={c.id}>
            <CalendarDays size={13} />
            {c.name}
          </span>
        ))}
      </div>
      {!share.outgoing && (
        <p className="fine-print">
          {labels[share.permission]} · Read-only
          {pending
            ? ". Accept to let your Calshot agent read these calendars."
            : " · Ask your agent about these calendars."}
        </p>
      )}
      {!pending &&
        !share.outgoing &&
        share.calendars.map((c) => (
          <div key={c.id}>
            <p className="fine-print">
              {c.name} · Last synced{" "}
              {formatDate(c.syncedAt, undefined, {
                hour: "numeric",
                minute: "2-digit",
              })}
              {c.stale ? " · Out of date" : ""}
            </p>
            <InlineError
              message={
                c.error ||
                (c.stale
                  ? "This copy may be out of date. Ask your friend to open Calshot and sync before relying on availability."
                  : undefined)
              }
            />
          </div>
        ))}
      {pending && (
        <p className="fine-print">
          Expires {formatDate(share.expiresAt)}.{" "}
          {share.outgoing
            ? "Your friend must accept in their account."
            : "Accepting doesn’t share any of your calendars back."}
        </p>
      )}
      <InlineError message={error} />
      {expired && (
        <button
          className="text-button"
          disabled={locked}
          onClick={() => void change(true)}
        >
          Dismiss expired request
        </button>
      )}
      {!expired && (
        <div className="sharing-person-actions">
          {!share.outgoing && pending ? (
            <>
              <button
                className="button secondary"
                disabled={locked}
                onClick={() =>
                  void run("respondCalendarRequest", {
                    requestID: share.id,
                    accept: false,
                  })
                }
              >
                Decline
              </button>
              <button
                className="button primary"
                disabled={locked}
                onClick={() =>
                  void run("respondCalendarRequest", {
                    requestID: share.id,
                    accept: true,
                  })
                }
              >
                Accept sharing
              </button>
            </>
          ) : share.outgoing ? (
            <>
              <Select
                label={`Access for ${share.personName}`}
                value={permission}
                onChange={(value) => setPermission(value as SharingPermission)}
                disabled={locked}
              >
                {Object.entries(labels).map(([value, label]) => (
                  <option key={value} value={value}>
                    {label}
                  </option>
                ))}
              </Select>
              <button
                className="button secondary"
                disabled={
                  locked ||
                  permission === share.permission ||
                  state.running ||
                  state.saving
                }
                onClick={() => void change(false)}
              >
                Save access
              </button>
              <button
                className="text-button danger"
                disabled={locked}
                onClick={() => void change(true)}
              >
                {pending ? "Cancel request" : "Stop sharing"}
              </button>
            </>
          ) : (
            <>
              <button
                className="button secondary"
                disabled={locked}
                onClick={() => void onAction("navigate", { page: "calendars" })}
              >
                View calendars
              </button>
              <button
                className="text-button danger"
                disabled={locked}
                onClick={() => void change(true)}
              >
                Remove access
              </button>
            </>
          )}
        </div>
      )}
    </article>
  );
}
