import { OnboardingScreen } from "./OnboardingScreen";
import { useState } from "react";
import { CalendarDays, Check, ArrowRight, ShieldCheck } from "lucide-react";
import { command } from "../bridge";
import type { AppState } from "../types";
import { InlineError, Spinner } from "../components/ui";

export function AccountScreen({ state }: { state: AppState }) {
  const auth = state.auth!;
  const [mode, setMode] = useState<"signIn" | "signUp" | "reset">("signIn");
  const [email, setEmail] = useState(auth.email || "");
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const busy = working || auth.busy;
  const onboarding =
    auth.signedIn && !auth.onboarded && auth.phase !== "passwordRecovery";
  const run = async (action: string, values: Record<string, unknown> = {}) => {
    if (busy) return;
    setWorking(true);
    setError("");
    setMessage("");
    try {
      await command({ action, ...values });
      if (["authSignIn", "authSignUp", "authChangePassword"].includes(action))
        setPassword("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setWorking(false);
    }
  };
  if (onboarding) return <OnboardingScreen state={state} />;
  return (
    <main className="account-page">
      <aside className="account-hero" aria-label="About Calshot">
        <div className="account-hero-brand">
          <span className="account-logo">
            <CalendarDays size={23} />
          </span>
          <strong>Calshot</strong>
        </div>
        <h1>
          Screenshot it.
          <br />
          It’s on your calendar.
        </h1>
        <p>
          Capture a syllabus, a shift roster or a poster. Calshot reads it, asks
          if anything’s unclear, and adds it after you say OK.
        </p>
        <div className="account-illustration" aria-hidden="true">
          <div className="illustration-sheet">
            <strong>Your schedule</strong>
            {["Classes", "Shifts", "Meetings", "Deadlines"].map((t) => (
              <div key={t}>
                {t}
                <span>— —</span>
              </div>
            ))}
          </div>
          <div className="illustration-event">
            <Check size={16} />
            <span>
              Review every event
              <br />
              <small>You’re always in control</small>
            </span>
          </div>
          <div className="illustration-event second">
            <CalendarDays size={16} />
            Your calendars, together
          </div>
        </div>
        <small>
          Works with iCloud, Google and the calendars already on your Mac.
        </small>
      </aside>
      <div className="account-form-side">
        <div className="account-brand">
          <CalendarDays size={20} />
          <strong>Calshot</strong>
        </div>
        <section
          className="account-panel"
          aria-label={onboarding ? "Connect your calendars" : "Calshot account"}
        >
          {!["verifyEmail", "passwordRecovery", "restoring"].includes(
            auth.phase,
          ) &&
            mode !== "reset" && (
              <div className="account-tabs" aria-label="Account options">
                {(["signIn", "signUp"] as const).map((m) => (
                  <button
                    key={m}
                    aria-pressed={mode === m}
                    onClick={() => {
                      setMode(m);
                      setPassword("");
                      setError("");
                    }}
                  >
                    {m === "signIn" ? "Sign in" : "Create account"}
                  </button>
                ))}
              </div>
            )}
          <div className="account-symbol">
            {onboarding ? (
              <CalendarDays size={27} />
            ) : (
              <ShieldCheck size={27} />
            )}
          </div>
          <h1>
            {onboarding
              ? "Make yourself at home"
              : auth.phase === "passwordRecovery"
                ? "Choose a new password"
                : mode === "signUp"
                  ? "Create your account"
                  : mode === "reset"
                    ? "Reset your password"
                    : "Welcome back"}
          </h1>
          <p className="account-subtitle">
            {onboarding
              ? "Bring your calendars together. Existing connections on this Mac are ready to use."
              : mode === "signUp"
                ? "Your calendar starts here. Make yourself at home."
                : "Sign in to pick up where you left off."}
          </p>
          {auth.phase === "restoring" ? (
            <div className="account-restoring" role="status">
              <Spinner />
              Checking your saved account…
            </div>
          ) : auth.phase === "verifyEmail" ? (
            <>
              <p className="account-message" role="status">
                Check {auth.email || email} for your confirmation email. Open
                its link on this Mac, or enter the code if your email includes
                one.
              </p>
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  void run("authVerify", { code });
                }}
                className="account-form"
              >
                <label>
                  Confirmation code
                  <input
                    inputMode="numeric"
                    autoComplete="one-time-code"
                    maxLength={12}
                    value={code}
                    onChange={(e) => setCode(e.target.value)}
                  />
                </label>
                <button
                  className="button primary"
                  disabled={busy || code.length < 6}
                >
                  {busy ? <Spinner /> : "Confirm email"}
                </button>
              </form>
              <button
                className="text-button"
                disabled={busy}
                onClick={() => void run("authResend")}
              >
                Resend confirmation email
              </button>
              <button
                className="text-button"
                disabled={busy}
                onClick={() => {
                  setMode("signIn");
                  void run("authRestore");
                }}
              >
                Already confirmed? Sign in
              </button>
            </>
          ) : (
            <>
              {mode !== "reset" && auth.phase !== "passwordRecovery" && (
                <>
                  <button
                    className="button secondary account-provider"
                    disabled={busy || !auth.googleEnabled}
                    onClick={() => void run("authGoogle")}
                  >
                    <span className="google-letter" aria-hidden>
                      G
                    </span>
                    Continue with Google
                  </button>
                  {!auth.googleEnabled && (
                    <p className="account-provider-note">
                      Google sign-in isn’t available yet. You can use email
                      below.
                    </p>
                  )}
                  <div className="account-divider">
                    <span />
                    or use email
                    <span />
                  </div>
                </>
              )}
              <form
                className="account-form"
                onSubmit={(e) => {
                  e.preventDefault();
                  void run(
                    auth.phase === "passwordRecovery"
                      ? "authChangePassword"
                      : mode === "signUp"
                        ? "authSignUp"
                        : mode === "reset"
                          ? "authReset"
                          : "authSignIn",
                    {
                      email: email.trim(),
                      password,
                      ...(mode === "signUp" ? { name: name.trim() } : {}),
                    },
                  );
                }}
              >
                {mode === "signUp" && auth.phase !== "passwordRecovery" && (
                  <label>
                    Name
                    <input
                      autoComplete="name"
                      placeholder="Your name"
                      maxLength={100}
                      value={name}
                      disabled={busy}
                      onChange={(e) => setName(e.target.value)}
                    />
                  </label>
                )}
                {auth.phase !== "passwordRecovery" && (
                  <label>
                    Email
                    <input
                      type="email"
                      autoComplete="email"
                      required
                      maxLength={254}
                      value={email}
                      disabled={busy}
                      onChange={(e) => setEmail(e.target.value)}
                      placeholder="you@example.com"
                    />
                  </label>
                )}
                {(mode !== "reset" || auth.phase === "passwordRecovery") && (
                  <label>
                    Password
                    <input
                      type="password"
                      autoComplete={
                        mode === "signUp" || auth.phase === "passwordRecovery"
                          ? "new-password"
                          : "current-password"
                      }
                      required
                      minLength={
                        mode === "signUp" || auth.phase === "passwordRecovery"
                          ? 12
                          : 1
                      }
                      maxLength={256}
                      value={password}
                      disabled={busy}
                      onChange={(e) => setPassword(e.target.value)}
                      placeholder={
                        mode === "signUp"
                          ? "At least 12 characters"
                          : "Your password"
                      }
                    />
                  </label>
                )}
                <InlineError message={error || auth.error} />
                <button
                  className="button primary account-submit"
                  disabled={busy}
                >
                  {busy ? (
                    <Spinner />
                  ) : (
                    <>
                      {auth.phase === "passwordRecovery"
                        ? "Save new password"
                        : mode === "signUp"
                          ? "Create account"
                          : mode === "reset"
                            ? "Send reset link"
                            : "Sign in"}
                      <ArrowRight size={15} />
                    </>
                  )}
                </button>
              </form>
              <div className="account-form-links">
                <button
                  className="text-button"
                  disabled={busy}
                  onClick={() => {
                    setMode(mode === "signUp" ? "signIn" : "signUp");
                    setError("");
                    setPassword("");
                  }}
                >
                  {mode === "signUp"
                    ? "Already have an account? Sign in"
                    : "New here? Create an account"}
                </button>
                <button
                  className="text-button"
                  disabled={busy}
                  onClick={() => {
                    setMode(mode === "reset" ? "signIn" : "reset");
                    setPassword("");
                    setError("");
                  }}
                >
                  {mode === "reset" ? "Back to sign in" : "Forgot password?"}
                </button>
              </div>
            </>
          )}
          {(onboarding || auth.phase === "verifyEmail") && (
            <InlineError message={error || auth.error} />
          )}
          {(message || auth.message) && (
            <p className="account-message" role="status">
              {message || auth.message}
            </p>
          )}
          {auth.error && !busy && (
            <button
              className="text-button"
              onClick={() => void run("authRestore")}
            >
              Retry saved account
            </button>
          )}
        </section>
        <p className="account-footnote">
          Your profile, preferences, accounts and task history sync with
          Calshot. Screenshots and connection credentials stay on each Mac.
        </p>
      </div>
    </main>
  );
}
