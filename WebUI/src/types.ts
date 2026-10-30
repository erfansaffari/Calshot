export type Page = "chat" | "capture" | "calendars" | "tasks" | "library" | "settings";
export interface Draft {
  taskID?: string;
  sourceRegion?: { x: number; y: number; width: number; height: number };
  id: string;
  title: string;
  startDate?: string;
  endDate?: string;
  isAllDay: boolean;
  timeZoneIdentifier?: string;
  location?: string;
  url?: string;
  notes?: string;
  sourceText: string;
  ambiguities: string[];
}
export interface Proposal {
  sourceImageURL?: string;
  id: string;
  operation: "create" | "update" | "delete" | "move";
  state: string;
  draft: Draft;
  before?: Draft;
  isSelected: boolean;
  isFinished: boolean;
  isApprovable: boolean;
  canSelect: boolean;
  inScope: boolean;
  status: string;
  issues: string[];
  error?: string;
  targetCalendarName?: string;
  sourceCalendarName?: string;
  moveCopyReceipt?: unknown;
  moveDestinationBefore?: Draft;
  receipt?: { calendarName: string; eventIdentifier: string };
  duplicateIdentifiers: string[];
  allowDuplicate: boolean;
}
export interface Turn {
  role: string;
  content?: string;
  toolName?: string;
  arguments?: string;
  result?: string;
  callID?: string;
}
export type SharingPermission = "busy" | "titles" | "details";
export interface SharedSource {
  id: string;
  sourceKey: string;
  name: string;
  revision: number;
  withdrawn: boolean;
  syncedAt: string;
  coverageStart: string;
  coverageEnd: string;
  error?: string | null;
}
export interface FriendCalendar {
  id: string;
  name: string;
  syncedAt: string;
  stale: boolean;
  error?: string | null;
}
export interface CalendarShare {
  id: string;
  ownerID: string;
  recipientID?: string;
  outgoing: boolean;
  personName: string;
  email?: string;
  permission: SharingPermission;
  status: "pending" | "accepted" | "expired";
  expiresAt: string;
  calendars: FriendCalendar[];
}
export interface SharingState {
  loaded: boolean;
  busy: boolean;
  error?: string | null;
  token: string;
  sources: SharedSource[];
  shares: CalendarShare[];
}
export function friendCalendarID(shareID: string, calendarID: string) {
  return `shared:${shareID}:${calendarID}`.toLowerCase();
}
export function friendCalendars(state: AppState): CalendarInfo[] {
  if (!state.sharing?.loaded || state.sharing.error) return [];
  const rank = { busy: 0, titles: 1, details: 2 };
  const seen = new Set<string>();
  return [...state.sharing.shares]
    .sort((a, b) => rank[b.permission] - rank[a.permission])
    .filter((s) => !s.outgoing && s.status === "accepted")
    .flatMap((s) =>
      s.calendars
        .filter((c) => {
          const key = `${s.ownerID}:${c.id}`;
          if (seen.has(key)) return false;
          seen.add(key);
          return true;
        })
        .map((c) => ({
          id: friendCalendarID(s.id, c.id),
          title: c.name,
          provider: "friend",
          sourceName: s.personName,
          isReadOnly: true,
          direct: false,
          unavailable: false,
        })),
    );
}
export interface CalendarInfo {
  id: string;
  title: string;
  provider: string;
  sourceName: string;
  isReadOnly: boolean;
  direct: boolean;
  unavailable: boolean;
}
export interface Account {
  id: string;
  email: string;
  provider: string;
  unavailable: boolean;
}
export interface MemoryRecord {
  id: string;
  title: string;
  createdAt: string;
  imageURL?: string;
  completed: number;
  count: number;
  provider: string;
}
export interface CalendarEvent {
  selectionHandle?: string;
  selectionGeneration?: string;
  eventIdentifier: string;
  calendarIdentifier: string;
  title: string;
  start: string;
  end: string;
  isAllDay: boolean;
  timeZone?: string;
  location?: string;
  calendarName: string;
  sourceName: string;
  url?: string;
  notes?: string;
  isRecurring?: boolean | null;
}
export interface CalendarViewState {
  loading: boolean;
  loaded: boolean;
  start?: string;
  end?: string;
  events: CalendarEvent[];
  errors: {
    calendarIdentifier: string;
    calendarName: string;
    message: string;
  }[];
  truncated?: boolean;
}
export interface AccountSyncState {
  busy: boolean;
  status: string;
  displayName: string;
  deviceID: string;
  lastSyncedAt?: string;
  error?: string;
  devices: Record<
    string,
    {
      name: string;
      updatedAt: string;
      connections: { key: string; provider: string; label: string }[];
    }
  >;
}
export interface SoftwareUpdateState {
  version: string; build: string; available: boolean; canCheck: boolean; checking: boolean;
  status: string; error?: string | null; automaticChecks: boolean; automaticDownloads: boolean;
  lastChecked?: string | null; development: boolean;
}
export interface TaskReviewChange { label: string; before?: string | null; after?: string | null }
export interface TaskReviewRow { id: string; title: string; note?: string | null; changes: TaskReviewChange[] }
/** Task-only review. Native owns the token and digest; it never carries a calendar write. */
export interface TaskReview {
  id: string; token: string; digest: string; kind: "link" | "edit" | "complete" | "archive";
  heading: string; phase: "waiting" | "applying"; reason: string; calendarWrites: number;
  error?: string | null; rows: TaskReviewRow[];
}
export interface TaskOutcome {
  id: string; status: "saved" | "partial" | "failed" | "cancelled" | "declined" | "denied" | "unavailable";
  headline: string; viaSavedPermission: boolean;
  rows: { id: string; title: string; status: string; message?: string | null }[];
}
/** Device-local task action grants for requests the user makes. Calendar changes are not covered. */
export interface AgentPermissionsState {
  loaded: boolean; busy: boolean; error?: string | null; notice?: string | null; revision: number;
  families: { id: string; label: string; detail: string; enabled: boolean; expired: boolean }[];
  expiresAt?: string | null; limits: { perRun: number; perWindow: number; windowMinutes: number };
  calendar?: { families: { id: string; label: string; detail: string; enabled: boolean; expired: boolean; alwaysAsks: boolean }[];
    calendarIDs: string[]; expiresAt?: string | null; notice?: string | null };
}
export interface VoiceState {
  token: string; state: string; active: boolean; inputLevel: number; caption: string; userTranscript: string; drawing: boolean;
  usage: { seconds: number; estimatedCost: number }; error?: string; needsKey: boolean; needsAcknowledgement: boolean; talking?: boolean; shortcut?: string; outputLevel?: number;
  permissions: { microphone: boolean; screen: boolean }; model: string; voice: string; monthlyCap: number;
}
export interface AppState {
  /** Native presentation only; omitted in the full workspace and browser fixtures. */
  notchExpanded?: boolean;
  voice?: VoiceState;
  voiceShortcut?: string;
  taskReview?: TaskReview;
  taskOutcome?: TaskOutcome;
  agentPermissions?: AgentPermissionsState;
  taskImport?: { id:string; items:CalshotTask[]; selectedInboxIDs:string[] };
  tasks?: TasksState;
  softwareUpdate?: SoftwareUpdateState;
  accountSync?: AccountSyncState;
  webCalendarSync?: {
    busy: boolean;
    error?: string | null;
    sourceKeys: Record<string, string>;
    mirrors: {
      id: string;
      sourceKey: string;
      generation: string;
      enabled: boolean;
      name: string;
      syncedAt?: string;
      complete: boolean;
      error?: string;
    }[];
  };
  auth?: {
    required: boolean;
    signedIn: boolean;
    phase: string;
    busy: boolean;
    onboarded: boolean;
    googleEnabled: boolean;
    signInProvider?: "google" | "email";
    identityProviders?: string[];
    aiSetupConfirmed?: boolean;
    email?: string;
    userID?: string;
    message?: string;
    error?: string;
  };
  settingsSection?: "general" | "calendars" | "friends" | "ai" | "voice" | "privacy";
  calendarView?: CalendarViewState;
  /** From the provider receipt of the last direct Calendar change. */
  calendarChange?: { operation: "create" | "update" | "delete"; title: string; calendarName: string; thisDateOnly?: boolean } | null;
  /** An interrupted Calendar or Tasks save that was confirmed, or couldn't be. */
  directWriteNotice?: string | null;
  calendarTaskNotices?: Record<string, { status: "loading" | "success" | "error"; message?: string; receipt?: { operationID: string; taskID: string; taskVersion: string; outcome: string; savedAt: string } }>;
  sharing?: SharingState;
  sidebarExpanded: boolean;
  sidebarWidth?: number;
  duplicateComparisons?: Record<string, Draft[]>;
  ready: boolean;
  native: boolean;
  page: Page;
  status?: string;
  notice?: string;
  imageURL?: string;
  captureID?: string;
  ocr: string;
  isCapturing: boolean;
  isRecognizing: boolean;
  running: boolean;
  streaming: string;
  agentStatus?: string;
  summary?: string;
  agentError?: string;
  canRetry: boolean;
  messages: Turn[];
  question?: { id: string; question: string; choices: string[] };
  waitingApproval: boolean;
  proposals: Proposal[];
  approvalToken: string;
  canApprove: boolean;
  selectedCount: number;
  checking: boolean;
  saving: boolean;
  reviewMessage?: string;
  calendars: CalendarInfo[];
  selectedCalendarID: string;
  calendarMessage?: string;
  accounts: Account[];
  connecting: boolean;
  connectingProvider?: string;
  accountMessage?: string;
  accountError: boolean;
  googleReady: boolean;
  googleClientID: string;
  outlookClientID: string;
  personalMemory?: PersonalMemoryState;
  memory: MemoryRecord[];
  memoryLocation: string;
  shortcut: string;
  screenPermissionNeeded: boolean;
  screenPermissionGranted?: boolean;
  settings: {
    appearance: "system" | "light" | "dark";
    agentEnabled: boolean;
    apiKeySaved: boolean;
    useAPIKey: boolean;
    chatGPTEmail?: string;
    chatGPTPlan: boolean;
    chatGPTConnecting?: boolean;
    chatGPTError?: string;
    model: string;
    models: { id: string; name: string }[];
    copyCaptures: boolean;
    /** Device-local; on unless the user turned the notch off. */
    notchEnabled?: boolean;
  };
}
export interface Command {
  action: string;
  [key: string]: unknown;
}
declare global {
  interface Window {
    __calshotSurface?: "notch";
    webkit?: {
      messageHandlers: { calshot: { postMessage: (message: unknown) => void } };
    };
    __calshotReceive?: (state: AppState) => void;
    __calshotReply?: (reply: {
      id: string;
      ok: boolean;
      error?: string;
    }) => void;
  }
}

export interface CalshotTask {
  calendarIntent?: "none" | "existing" | "new";
  intentProvenance?: "defaulted" | "explicit" | "suppressed";
  sourceLink?: { deviceID: string; calendarID: string; eventID: string; occurrenceKey: string; observedStart: string; observedEnd: string; observedAt: string; sourceName: string; calendarName: string };
  id: string; version: string; title: string; dueDate?: string; dueTime?: string; timeZone: string; notes: string;
  completed: boolean; deleted: boolean; rank: number; reminderMinutes?: number; reminderTime?: string; reminderDeviceID?: string;
  calendarID?: string; calendarName?: string; receipt?: {eventIdentifier:string;destinationID:string;calendarName:string};
  receiptDeviceID?: string; publishedFingerprint?: string; calendarError?: string; sourceText?: string;
}
export interface TasksState { items: CalshotTask[]; token: string; loaded: boolean; busy: boolean; conflict?: boolean; error?: string; reminderError?: string; deviceID: string }

export interface PersonalMemoryItem {
  id: string;
  version: string;
  kind: "preference" | "fact" | "person" | "routine";
  text: string;
  origin: "explicit" | "suggested";
  status: "active" | "pendingApproval";
  createdAt: string;
  updatedAt: string;
  expiresAt?: string;
}
export interface PersonalMemoryState {
  loaded: boolean;
  error?: string | null;
  items: PersonalMemoryItem[];
  pending: PersonalMemoryItem[];
  token: string;
}
