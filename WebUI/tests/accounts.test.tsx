import { afterEach, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AccountScreen } from "../src/views/AccountScreen";
import { preview } from "../src/preview";
import type { AppState } from "../src/types";
vi.mock("../src/bridge", () => ({
  command: vi.fn().mockResolvedValue(undefined),
}));
import { command } from "../src/bridge";
const auth = {
  required: true,
  signedIn: false,
  phase: "signedOut",
  busy: false,
  onboarded: false,
  googleEnabled: true,
  signInProvider: "google" as const,
  aiSetupConfirmed: false,
};
function onboarding(settings = preview.settings): AppState {
  return {
    ...preview,
    auth: {
      ...auth,
      signedIn: true,
      phase: "signedIn",
      email: "alex@example.invalid",
    },
    settings,
  };
}
afterEach(() => {
  cleanup();
  vi.mocked(command).mockClear();
});
it("sends sign-in credentials through native auth and clears the password", async () => {
  render(<AccountScreen state={{ ...preview, auth }} />);
  await userEvent.type(
    screen.getByRole("textbox", { name: "Email" }),
    "alex@example.invalid",
  );
  await userEvent.type(
    screen.getByLabelText("Password"),
    "fictional-password-123",
  );
  await userEvent.click(
    screen.getAllByRole("button", { name: "Sign in", exact: true }).at(-1)!,
  );
  expect(command).toHaveBeenCalledWith({
    action: "authSignIn",
    email: "alex@example.invalid",
    password: "fictional-password-123",
  });
  expect((screen.getByLabelText("Password") as HTMLInputElement).value).toBe(
    "",
  );
});
it("preserves email and shows sign-in errors in the form", async () => {
  render(<AccountScreen state={{ ...preview, auth }} />);
  await userEvent.type(
    screen.getByRole("textbox", { name: "Email" }),
    "alex@example.invalid",
  );
  await userEvent.type(
    screen.getByLabelText("Password"),
    "fictional-password-123",
  );
  vi.mocked(command).mockRejectedValueOnce(
    new Error("Check your email and password."),
  );
  await userEvent.click(
    screen.getAllByRole("button", { name: "Sign in", exact: true }).at(-1)!,
  );
  expect(screen.getByRole("alert").textContent).toContain(
    "Check your email and password.",
  );
  expect(
    (screen.getByRole("textbox", { name: "Email" }) as HTMLInputElement).value,
  ).toBe("alex@example.invalid");
});
it("offers only Google and email sign-in even when a ChatGPT plan is connected", () => {
  render(<AccountScreen state={{ ...preview, auth, settings: { ...preview.settings, chatGPTPlan: true, chatGPTConnecting: true } }} />);
  expect(screen.queryByRole("button", { name: "Continue with ChatGPT" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Connect ChatGPT" })).toBeNull();
  expect(screen.queryByText(/OpenAI registration/)).toBeNull();
  expect((screen.getByRole("button", { name: "Continue with Google" }) as HTMLButtonElement).disabled).toBe(false);
  expect(screen.getByLabelText("Email")).toBeTruthy();
});
it("routes Google through native identity and defers calendar authorization", async () => {
  render(<AccountScreen state={{ ...preview, auth }} />);
  await userEvent.click(
    screen.getByRole("button", { name: "Continue with Google" }),
  );
  expect(command).toHaveBeenCalledWith({ action: "authGoogle" });
  expect(
    vi.mocked(command).mock.calls.some(([c]) => c.action === "connectGoogle"),
  ).toBe(false);
});
it("starts Google onboarding with required AI setup before calendars", () => {
  render(
    <AccountScreen
      state={onboarding({
        ...preview.settings,
        chatGPTPlan: false,
        apiKeySaved: false,
      })}
    />,
  );
  expect(
    screen.getByRole("heading", { name: "Set up your AI assistant" }),
  ).toBeTruthy();
  expect(
    (
      screen.getByRole("button", {
        name: "Continue",
        exact: true,
      }) as HTMLButtonElement
    ).disabled,
  ).toBe(true);
  expect(screen.queryByRole("button", { name: "Skip for now" })).toBeNull();
  expect(
    screen.queryByRole("heading", { name: "Confirm your calendars" }),
  ).toBeNull();
});
it("connects ChatGPT without selecting billing until the user confirms it", async () => {
  render(
    <AccountScreen
      state={onboarding({
        ...preview.settings,
        chatGPTPlan: false,
        chatGPTEmail: undefined,
      })}
    />,
  );
  await userEvent.click(
    screen.getByRole("button", { name: "Connect ChatGPT" }),
  );
  expect(command).toHaveBeenCalledWith({ action: "connectChatGPT" });
  expect(
    vi.mocked(command).mock.calls.some(([c]) => c.action === "authConfirmAI"),
  ).toBe(false);
});
it("confirms a connected ChatGPT plan and then shows calendar confirmation", async () => {
  render(
    <AccountScreen
      state={onboarding({
        ...preview.settings,
        chatGPTPlan: true,
        chatGPTError: undefined,
      })}
    />,
  );
  await userEvent.click(
    screen.getByRole("button", { name: "Use ChatGPT plan" }),
  );
  expect(command).toHaveBeenCalledWith({
    action: "authConfirmAI",
    provider: "chatgpt",
  });
  expect(
    screen.getByRole("heading", { name: "Confirm your calendars" }),
  ).toBeTruthy();
});
it("saves an API key natively, selects it explicitly, then confirms calendars", async () => {
  render(<AccountScreen state={onboarding()} />);
  await userEvent.type(
    screen.getByLabelText("API key"),
    "sk-fictional-test-key",
  );
  await userEvent.click(
    screen.getByRole("button", { name: "Save and use API key" }),
  );
  expect(command).toHaveBeenCalledWith({
    action: "saveAPIKey",
    key: "sk-fictional-test-key",
  });
  expect(command).toHaveBeenCalledWith({
    action: "authConfirmAI",
    provider: "api",
  });
  expect(
    screen.getByRole("heading", { name: "Confirm your calendars" }),
  ).toBeTruthy();
});
it("keeps a rejected API key and stays in AI setup", async () => {
  render(<AccountScreen state={onboarding()} />);
  vi.mocked(command).mockRejectedValueOnce(new Error("Enter a valid API key."));
  await userEvent.type(screen.getByLabelText("API key"), "fictional-invalid");
  await userEvent.click(
    screen.getByRole("button", { name: "Save and use API key" }),
  );
  expect(screen.getByRole("alert").textContent).toContain(
    "Enter a valid API key.",
  );
  expect((screen.getByLabelText("API key") as HTMLInputElement).value).toBe(
    "fictional-invalid",
  );
  expect(
    vi.mocked(command).mock.calls.some(([c]) => c.action === "authConfirmAI"),
  ).toBe(false);
});
it("resumes calendar confirmation only after AI setup was confirmed", () => {
  const state = onboarding({
    ...preview.settings,
    chatGPTPlan: true,
    chatGPTError: undefined,
  });
  state.auth = {
    ...state.auth!,
    signInProvider: "email",
    aiSetupConfirmed: true,
  };
  render(<AccountScreen state={state} />);
  expect(
    screen.getByRole("heading", { name: "Confirm your calendars" }),
  ).toBeTruthy();
  expect(screen.queryByLabelText("API key")).toBeNull();
});
it("requires AI setup after email sign-up", () => {
  const state = onboarding({ ...preview.settings, chatGPTPlan: false });
  state.auth = {
    ...state.auth!,
    signInProvider: "email",
    aiSetupConfirmed: false,
  };
  render(<AccountScreen state={state} />);
  expect(
    screen.getByRole("heading", { name: "Set up your AI assistant" }),
  ).toBeTruthy();
});
it("requires calendar confirmation, preserves existing connections and finishes setup", async () => {
  const state = onboarding();
  state.auth = { ...state.auth!, aiSetupConfirmed: true };
  const view = render(<AccountScreen state={{ ...state, calendars: [] }} />);
  expect(
    (
      screen.getByRole("button", {
        name: "Continue",
        exact: true,
      }) as HTMLButtonElement
    ).disabled,
  ).toBe(true);
  await userEvent.click(screen.getByRole("button", { name: "Allow access" }));
  expect(command).toHaveBeenCalledWith({ action: "refreshCalendars" });
  view.rerender(<AccountScreen state={state} />);
  await userEvent.click(
    screen.getByRole("button", { name: "Continue", exact: true }),
  );
  await userEvent.click(screen.getByRole("button", { name: "Skip for now" }));
  await userEvent.click(
    screen.getByRole("button", { name: "Continue", exact: true }),
  );
  await userEvent.click(screen.getByRole("button", { name: "Go to Calshot" }));
  expect(command).toHaveBeenCalledWith({ action: "authFinish" });
  expect(
    vi.mocked(command).mock.calls.some(([c]) => c.action === "connectGoogle"),
  ).toBe(false);
});
it("supports cancelling ChatGPT and shows its error without advancing", async () => {
  const state = onboarding({ ...preview.settings, chatGPTConnecting: true });
  const view = render(<AccountScreen state={state} />);
  await userEvent.click(
    screen.getByRole("button", { name: "Cancel ChatGPT connection" }),
  );
  expect(command).toHaveBeenCalledWith({ action: "cancelChatGPT" });
  view.rerender(
    <AccountScreen
      state={{
        ...state,
        settings: {
          ...state.settings,
          chatGPTConnecting: false,
          chatGPTError: "Connection expired. Reconnect.",
        },
      }}
    />,
  );
  expect(screen.getByRole("alert").textContent).toContain(
    "Connection expired. Reconnect.",
  );
  expect(
    screen.getByRole("heading", { name: "Set up your AI assistant" }),
  ).toBeTruthy();
});
it("keeps verification and password recovery outside onboarding", async () => {
  const view = render(
    <AccountScreen
      state={{
        ...preview,
        auth: { ...auth, phase: "verifyEmail", email: "alex@example.invalid" },
      }}
    />,
  );
  await userEvent.type(
    screen.getByRole("textbox", { name: "Confirmation code" }),
    "123456",
  );
  await userEvent.click(screen.getByRole("button", { name: "Confirm email" }));
  expect(command).toHaveBeenCalledWith({
    action: "authVerify",
    code: "123456",
  });
  view.rerender(
    <AccountScreen
      state={{ ...preview, auth: { ...auth, phase: "passwordRecovery" } }}
    />,
  );
  expect(screen.getByLabelText("Password")).toBeTruthy();
});

it("connects Google Calendar without routing users to developer setup", async () => {
  const { OnboardingScreen } = await import("../src/views/OnboardingScreen");
  const state = onboarding(); state.auth = { ...state.auth!, aiSetupConfirmed:true }; state.googleReady = false;
  render(<OnboardingScreen state={state}/>);
  const connect = screen.getByRole("button", {name:"Connect Google Calendar"});
  expect((connect as HTMLButtonElement).disabled).toBe(false);
  await userEvent.click(connect);
  expect(command).toHaveBeenCalledWith({action:"connectGoogle"});
  expect(screen.queryByText(/setup is still being completed/)).toBeNull();
  await userEvent.click(screen.getByRole("button", {name:"Add Google through macOS"}));
  expect(command).toHaveBeenCalledWith({action:"internetAccountsSettings"});
});
it("offers the native Screen Recording helper during setup", async () => {
  const { OnboardingScreen } = await import("../src/views/OnboardingScreen");
  const state = onboarding(); state.auth = { ...state.auth!, aiSetupConfirmed:true };
  render(<OnboardingScreen state={state}/>);
  await userEvent.click(screen.getByRole("button", {name:/Continue/}));
  await userEvent.click(screen.getByRole("button", {name:"Set up Screen Recording"}));
  expect(command).toHaveBeenCalledWith({action:"screenSettings"});
});
