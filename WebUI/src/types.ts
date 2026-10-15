export type Page = "chat" | "capture" | "calendars" | "library" | "settings";
export interface Draft {
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
export interface AppState {
  sidebarExpanded: boolean;
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
  memory: MemoryRecord[];
  memoryLocation: string;
  shortcut: string;
  screenPermissionNeeded: boolean;
  settings: {
    appearance: "system" | "light" | "dark";
    agentEnabled: boolean;
    apiKeySaved: boolean;
    useAPIKey: boolean;
    chatGPTEmail?: string;
    chatGPTPlan: boolean;
    chatGPTError?: string;
    model: string;
    models: { id: string; name: string }[];
    copyCaptures: boolean;
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
