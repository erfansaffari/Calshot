import { useRef, useState } from "react";
import {
  CalendarDays,
  Check,
  ScanLine,
  ArrowRight,
  ChevronLeft,
  Monitor,
  Plus,
  Sparkles,
} from "lucide-react";
import { command } from "../bridge";
import { InlineError, Spinner } from "../components/ui";
import type { AppState } from "../types";

/** Presentation steps only; native snapshots decide permission and connection readiness. */
export function OnboardingScreen({ state }: { state: AppState }) {
  type Step = "ai" | "calendars" | "screen" | "shortcut" | "ready";
  const [step, setStep] = useState<Step>(
    state.auth?.aiSetupConfirmed ? "calendars" : "ai",
  );
  const [apiKey, setAPIKey] = useState("");
  const steps: Step[] = ["ai", "calendars", "screen", "shortcut", "ready"];
  const position = Math.max(0, steps.indexOf(step));
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const cancelledChatGPT = useRef(false);
  const ai = state.settings;
  const planReady = ai.chatGPTPlan && !ai.chatGPTError;
  const calendars = state.calendars.filter((c) => !c.unavailable);
  const busy = working || state.connecting || Boolean(ai.chatGPTConnecting);
  const run = async (action: string, fields: Record<string, unknown> = {}) => {
    if (working) return false;
    setWorking(true);
    setError("");
    setNotice("");
    if (action === "connectChatGPT") cancelledChatGPT.current = false;
    try {
      await command({ action, ...fields });
      return true;
    } catch (e) {
      if (action === "connectChatGPT" && cancelledChatGPT.current)
        setNotice("ChatGPT connection cancelled. You can try again.");
      else setError((e as Error).message);
      return false;
    } finally {
      setWorking(false);
    }
  };
  const finish = async (capture = false) => {
    if (await run("authFinish")) {
      if (capture) await run("capture");
    }
  };
  const titles: Record<Step, string> = {
    ai: "Set up your AI assistant",
    calendars: "Confirm your calendars",
    screen: "Let Calshot see what you capture",
    shortcut: "Capture from anywhere",
    ready: "You’re ready",
  };
  const descriptions: Record<Step, string> = {
    ai: "Choose your ChatGPT plan or an OpenAI API key. Then we’ll confirm your calendars.",
    calendars:
      "Use calendars already connected on this Mac, or connect an account. Nothing is added without approval.",
    screen:
      "macOS needs Screen Recording access to read the area you select. Calshot captures only when you ask.",
    shortcut: "Press the shortcut, or point at the notch, wherever you are.",
    ready:
      "Open a syllabus, roster or event page. Capture it, then review what Calshot finds.",
  };
  const confirmAI = async (provider: "api" | "chatgpt") => {
    if (await run("authConfirmAI", { provider })) setStep("calendars");
  };
  const next = async () => {
    if (step === "ai") await confirmAI(ai.useAPIKey ? "api" : "chatgpt");
    else {
      setError("");
      setStep(steps[Math.min(position + 1, steps.length - 1)]);
    }
  };
  return (
    <main className="setup-page">
      <header className="setup-header">
        <div
          className="setup-progress"
          role="progressbar"
          aria-label="Setup progress"
          aria-valuemin={1}
          aria-valuemax={steps.length}
          aria-valuenow={position + 1}
        >
          {steps.map((name, n) => (
            <span key={name} className={n <= position ? "complete" : ""} />
          ))}
        </div>
        <span>
          Step {position + 1} of {steps.length}
        </span>
      </header>
      <section className="setup-stage" aria-labelledby="setup-title">
        {step === "ready" && (
          <div className="setup-logo done">
            <Check size={32} />
          </div>
        )}
        <h1 id="setup-title">{titles[step]}</h1>
        <p className="setup-lead">{descriptions[step]}</p>
        {step === "calendars" && (
          <>
            <div className="card setup-calendar-card">
              <div className="setup-card-row">
                <CalendarDays />
                <div>
                  <strong>Calendars on this Mac</strong>
                  <p>
                    iCloud, Google, Outlook — whatever you’ve added to macOS
                    Calendar.
                  </p>
                </div>
                <button
                  className="button primary"
                  disabled={busy}
                  onClick={() => void run("refreshCalendars")}
                >
                  {working ? (
                    <Spinner />
                  ) : calendars.length ? (
                    "Refresh"
                  ) : (
                    "Allow access"
                  )}
                </button>
              </div>
              {calendars.length > 0 && (
                <>
                  <div className="setup-card-row">
                    <span className="setup-connected">
                      <Check size={13} />
                      Connected
                    </span>
                    <span>Found {calendars.length} calendars</span>
                  </div>
                  <div className="setup-calendar-list">
                    {calendars.map((c) => (
                      <div className="setup-card-row" key={c.id}>
                        <span className="setup-calendar-dot" />
                        <span>
                          {c.title}
                          <small>
                            {" "}
                            · {c.sourceName}
                            {c.isReadOnly ? " · Read only" : ""}
                          </small>
                        </span>
                        {c.id === state.selectedCalendarID && (
                          <small className="setup-destination">
                            New events go here
                          </small>
                        )}
                      </div>
                    ))}
                  </div>
                </>
              )}
            </div>
            {calendars.some((c) => !c.isReadOnly) && (
              <label className="setup-default">
                Default calendar
                <select
                  aria-label="Default calendar"
                  value={state.selectedCalendarID}
                  onChange={(e) =>
                    void run("selectCalendar", { calendarID: e.target.value })
                  }
                >
                  {calendars
                    .filter((c) => !c.isReadOnly)
                    .map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.title} · {c.sourceName}
                      </option>
                    ))}
                </select>
              </label>
            )}
            <button
              className="text-button setup-direct"
              disabled={busy || !state.googleReady}
              onClick={() => void run("connectGoogle")}
            >
              <Plus size={15} />
              Connect Google Calendar
            </button>
            {!state.googleReady && (
              <p className="fine-print">
                Direct Google Calendar setup is still being completed.
              </p>
            )}
            {state.connecting && (
              <>
                <p role="status">
                  <Spinner />
                  Finish calendar sign-in in your browser…
                </p>
                <button
                  className="text-button"
                  onClick={() => void run("cancelConnection")}
                >
                  Cancel calendar sign-in
                </button>
              </>
            )}
            {state.calendarMessage && (
              <p className="fine-print" role="status">
                {state.calendarMessage}
              </p>
            )}
            <InlineError
              message={state.accountError ? state.accountMessage : undefined}
            />
          </>
        )}
        {step === "ai" && (
          <div
            className="card setup-calendar-card setup-ai-card"
            aria-label="Connect ChatGPT"
          >
            <div className="setup-card-row">
              <Sparkles />
              <div>
                <strong>ChatGPT plan</strong>
                <p>
                  Use your eligible ChatGPT plan for Calshot’s AI requests.
                  OpenAI will show the permissions and usage limits.
                </p>
              </div>
              <span className={planReady ? "setup-connected" : "fine-print"}>
                {ai.chatGPTConnecting
                  ? "Connecting…"
                  : planReady
                    ? "Connected"
                    : ai.chatGPTEmail
                      ? "Reconnect needed"
                      : "Not connected"}
              </span>
            </div>
            {ai.chatGPTEmail && <p className="fine-print">{ai.chatGPTEmail}</p>}
            {ai.chatGPTConnecting ? (
              <>
                <p role="status">
                  <Spinner /> Finish ChatGPT sign-in in your browser, then
                  return here.
                </p>
                <button
                  className="button secondary"
                  onClick={() => {
                    cancelledChatGPT.current = true;
                    void command({ action: "cancelChatGPT" }).catch((e) =>
                      setError((e as Error).message),
                    );
                  }}
                >
                  Cancel ChatGPT connection
                </button>
              </>
            ) : (
              <div className="setup-card-row">
                <button
                  className={planReady ? "button secondary" : "button primary"}
                  disabled={busy}
                  onClick={() => void run("connectChatGPT")}
                >
                  {working ? <Spinner /> : <Sparkles size={16} />}
                  {ai.chatGPTEmail ? "Reconnect ChatGPT" : "Connect ChatGPT"}
                </button>
                {planReady && (
                  <button
                    className="button primary"
                    disabled={busy}
                    onClick={() => void confirmAI("chatgpt")}
                  >
                    Use ChatGPT plan
                  </button>
                )}
              </div>
            )}
            {ai.useAPIKey && ai.apiKeySaved && (
              <p className="fine-print">
                Your saved AI choice is OpenAI API key. Connecting ChatGPT won’t
                change it until you choose Use ChatGPT plan.
              </p>
            )}
            <InlineError message={ai.chatGPTError} />
            {notice && <p role="status">{notice}</p>}
          </div>
        )}
        {step === "ai" && (
          <div
            className="card setup-calendar-card setup-ai-card"
            aria-label="OpenAI API key"
          >
            <div className="setup-card-row">
              <div>
                <strong>OpenAI API key</strong>
                <p>
                  API usage is billed separately from a ChatGPT plan. The key
                  stays in this Mac’s Keychain.
                </p>
              </div>
            </div>
            {ai.apiKeySaved && (
              <div className="setup-card-row">
                <span className="setup-connected">API key saved</span>
                <button
                  className="button primary"
                  disabled={busy}
                  onClick={() => void confirmAI("api")}
                >
                  Use saved API key
                </button>
              </div>
            )}
            <form
              className="setup-api-form"
              onSubmit={async (e) => {
                e.preventDefault();
                if (await run("saveAPIKey", { key: apiKey.trim() })) {
                  setAPIKey("");
                  await confirmAI("api");
                }
              }}
            >
              <label>
                API key
                <input
                  type="password"
                  autoComplete="off"
                  spellCheck={false}
                  value={apiKey}
                  maxLength={256}
                  onChange={(e) => setAPIKey(e.target.value)}
                  disabled={busy}
                />
              </label>
              <button
                className="button primary"
                disabled={busy || !apiKey.trim()}
              >
                Save and use API key
              </button>
            </form>
          </div>
        )}
        {step === "screen" && (
          <div className="card setup-permission">
            <div className="setup-settings-label">
              SYSTEM SETTINGS › PRIVACY &amp; SECURITY › SCREEN RECORDING
            </div>
            <div className="setup-card-row">
              <Monitor />
              <strong>Calshot</strong>
              <span
                className={
                  state.screenPermissionGranted
                    ? "setup-connected"
                    : "fine-print"
                }
              >
                {state.screenPermissionGranted ? "Allowed" : "Access needed"}
              </span>
            </div>
            <p>
              {state.screenPermissionGranted
                ? "You’re ready to capture."
                : "Enable Calshot in the list, then return here. You can also do this later and use text commands for now."}
            </p>
            <button
              className="button primary"
              onClick={() => void run("screenSettings")}
            >
              Open System Settings
            </button>
          </div>
        )}
        {step === "shortcut" && (
          <>
            <div className="card setup-shortcut">
              <kbd>{state.shortcut}</kbd>
              <button
                className="button secondary"
                onClick={() => void run("advancedSettings")}
              >
                Change shortcut
              </button>
            </div>
            <div className="card setup-card-row">
              <ScanLine />
              <div>
                <strong>Quick actions in the notch</strong>
                <p>
                  Capture, answer questions and approve events without opening
                  the app.
                </p>
              </div>
              <Check size={18} />
            </div>
            <p className="fine-print">
              Calshot is available in the menu bar while the app is running.
            </p>
          </>
        )}
        {step === "ready" && (
          <>
            <div className="setup-final-actions">
              <button
                className="button primary"
                disabled={busy || !calendars.length}
                onClick={() => void finish(true)}
              >
                <ScanLine size={16} />
                Capture something now
              </button>
              <button
                className="button secondary"
                disabled={busy || !calendars.length}
                onClick={() => void finish()}
              >
                Go to Calshot
              </button>
            </div>
            {!calendars.length && (
              <p className="inline-error" role="alert">
                Connect an available calendar before continuing.
                <button
                  className="text-button"
                  onClick={() => setStep("calendars")}
                >
                  Connect calendars
                </button>
              </p>
            )}
            <p className="fine-print">
              Calendar changes always need your approval. Connecting calendars
              doesn’t share them with friends.
            </p>
          </>
        )}
        <InlineError message={error} />
      </section>
      <footer className="setup-footer">
        {position > 0 && (
          <button
            className="button ghost"
            disabled={busy}
            onClick={() => {
              setError("");
              setStep(steps[position - 1]);
            }}
          >
            <ChevronLeft size={15} />
            Back
          </button>
        )}
        <button
          className="text-button setup-signout"
          disabled={busy}
          onClick={() => void run("authSignOut")}
        >
          Sign out
        </button>
        <span />
        {step === "screen" && !state.screenPermissionGranted && (
          <button
            className="button ghost"
            disabled={busy}
            onClick={() => void next()}
          >
            Skip for now
          </button>
        )}
        {step !== "ready" && (
          <button
            className="button primary"
            disabled={
              busy ||
              (step === "calendars" && !calendars.length) ||
              (step === "ai" && !(ai.useAPIKey ? ai.apiKeySaved : planReady))
            }
            onClick={() => void next()}
          >
            Continue
            <ArrowRight size={15} />
          </button>
        )}
      </footer>
    </main>
  );
}
