import type { AppState, Proposal } from "./types";
const example = (id: string, date: string): Proposal => ({
  id,
  operation: "move",
  state: "pending",
  draft: {
    id,
    title: "Shift — Area A / FRSH",
    startDate: date + "T18:00:00Z",
    endDate: date + "T21:30:00Z",
    isAllDay: false,
    timeZoneIdentifier: "America/Toronto",
    location: "Area A / FRSH",
    sourceText: "From your work schedule",
    ambiguities: [],
  },
  isSelected: true,
  isFinished: false,
  isApprovable: true,
  canSelect: true,
  inScope: true,
  status: "Ready",
  issues: [],
  targetCalendarName: "Personal",
  sourceCalendarName: "Apple Calendar",
  duplicateIdentifiers: [],
  allowDuplicate: false,
});
export const preview: AppState = {
  sidebarExpanded: true,
  canRetry: false,
  ready: true,
  native: false,
  page: "chat",
  ocr: "",
  isCapturing: false,
  isRecognizing: false,
  running: false,
  streaming: "",
  waitingApproval: true,
  messages: [
    {
      role: "user",
      content:
        "Move my two shifts next week from Apple Calendar to my Google calendar.",
    },
    {
      role: "assistant",
      toolName: "search_events",
      result: JSON.stringify({
        events: [{}, {}],
        calendarName: "All connected calendars",
        calendars: [{}, {}],
      }),
    },
    {
      role: "assistant",
      content:
        "I found both shifts. Here’s the move from Apple Calendar to Personal. Review the details below, then approve when you’re ready.",
    },
  ],
  proposals: [example("one", "2026-10-20"), example("two", "2026-10-22")],
  approvalToken: "preview",
  canApprove: true,
  selectedCount: 2,
  checking: false,
  saving: false,
  calendars: [
    {
      id: "apple",
      title: "Apple Calendar",
      provider: "apple",
      sourceName: "iCloud",
      isReadOnly: false,
      direct: false,
      unavailable: false,
    },
    {
      id: "google",
      title: "Personal",
      provider: "google",
      sourceName: "Google",
      isReadOnly: false,
      direct: false,
      unavailable: false,
    },
    {
      id: "school",
      title: "Waterloo",
      provider: "google",
      sourceName: "Google",
      isReadOnly: false,
      direct: false,
      unavailable: false,
    },
  ],
  selectedCalendarID: "google",
  accounts: [
    {
      id: "preview-account",
      email: "alex@example.com",
      provider: "google",
      unavailable: false,
    },
  ],
  connecting: false,
  accountError: false,
  googleReady: true,
  googleClientID: "",
  outlookClientID: "",
  personalMemory: { loaded: true, items: [], pending: [], token: "preview-memory" },
  memory: [
    {
      id: "example",
      title: "Next week’s shifts",
      createdAt: "2026-10-14T18:00:00Z",
      completed: 0,
      count: 2,
      provider: "Calendar agent",
    },
  ],
  memoryLocation: "On your Mac",
  shortcut: "⌃⇧C",
  screenPermissionNeeded: false,
  settings: {
    appearance: "system",
    agentEnabled: true,
    apiKeySaved: true,
    useAPIKey: true,
    chatGPTPlan: false,
    model: "gpt-6-luna",
    models: [],
    copyCaptures: true,
    notchEnabled: true,
  },
};

// Explicit, isolated design fixtures. These never load unless ?preview=1 is set.
const scenario = new URLSearchParams(window.location.search).get("scenario");
const titles = [
  "Lab Report 1 due",
  "Quiz 1",
  "Problem Set 2 due",
  "Midterm Exam",
  "Lab Report 2 due",
  "Quiz 2",
  "Group presentation",
  "Problem Set 3 due",
  "Lab Report 3 due",
  "Quiz 3",
  "Final project due",
  "Final Exam",
];
const dates = [
  "2026-09-25",
  "2026-09-29",
  "2026-10-09",
  "2026-10-22",
  "2026-10-30",
  "2026-11-03",
  "2026-11-06",
  "2026-11-13",
  "2026-11-20",
  "2026-11-24",
  "2026-12-04",
  "2026-12-16",
];
if (scenario === "home") {
  preview.messages = [];
  preview.proposals = [];
  preview.waitingApproval = false;
  preview.canApprove = false;
  preview.selectedCount = 0;
  preview.memory = [];
}
if (scenario === "syllabus" || scenario === "partial") {
  preview.proposals = titles.map((title, i) => {
    const p = example("syllabus-" + i, dates[i]);
    p.operation = "create";
    p.draft.title = title;
    p.draft.isAllDay = i % 2 === 0;
    p.targetCalendarName = "School";
    p.draft.sourceText = title + " | " + dates[i];
    if (i === 6 || i === 9) {
      p.issues = [
        i === 6 ? "Choose a date." : "Choose a time or confirm all-day.",
      ];
      p.isSelected = false;
      p.canSelect = false;
      p.isApprovable = false;
      if (i === 6) p.draft.startDate = undefined;
    }
    if (i === 3) {
      p.duplicateIdentifiers = ["existing-midterm"];
      p.isSelected = false;
      p.isApprovable = false;
      p.canSelect = false;
      p.status = "Possible duplicate";
    }
    return p;
  });
  preview.messages = [
    {
      role: "user",
      content: "Add all the deadlines and tests to my School calendar.",
    },
    {
      role: "assistant",
      content:
        "I found 12 events. Two need details, and the midterm may already be on your calendar. Review the selected events below.",
    },
  ];
  preview.selectedCalendarID = "school";
  preview.calendars[2].title = "School";
  preview.selectedCount = 9;
  const rows = titles
    .map(
      (title, i) =>
        '<text x="24" y="' +
        (95 + i * 27) +
        '" font-size="11" fill="#424852">' +
        title +
        '</text><text x="240" y="' +
        (95 + i * 27) +
        '" font-size="11" fill="#68727f">' +
        dates[i].slice(5) +
        "</text>",
    )
    .join("");
  preview.imageURL =
    "data:image/svg+xml," +
    encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="440"><rect width="320" height="440" rx="4" fill="white"/><text x="24" y="35" font-family="sans-serif" font-size="17" font-weight="600" fill="#282b32">BIOL 210 — Cell Biology</text><text x="24" y="57" font-size="11" fill="#68727f">Assessment schedule · Fall 2026</text>' +
        rows +
        "</svg>",
    );
  preview.ocr = titles.map((t, i) => t + " | " + dates[i]).join("\n");
  if (scenario === "partial") {
    let added = 0;
    for (const p of preview.proposals) {
      if (p.isSelected && added < 7) {
        p.isFinished = true;
        p.state = "added";
        p.status = "Added";
        p.isSelected = false;
        p.receipt = { calendarName: "School", eventIdentifier: p.id };
        added++;
      } else if (p.isSelected) {
        p.state = "failed";
        p.status = "Failed";
        p.error = "Google Calendar did not respond in time.";
      }
    }
    preview.selectedCount = 2;
    preview.messages.push({
      role: "assistant",
      content:
        "7 events were added. Two did not save. You can retry only those two; completed events stay added.",
    });
    preview.waitingApproval = false;
  }
}
if (scenario === "question") {
  preview.running = true;
  preview.waitingApproval = false;
  preview.proposals = [];
  preview.selectedCount = 0;
  preview.canApprove = false;
  preview.messages = [
    { role: "user", content: "Move Thursday’s class to Friday." },
  ];
  preview.question = {
    id: "preview-question",
    question:
      "Which class on Thursday, October 15 should move to Friday at the same time?",
    choices: Array.from(
      { length: 6 },
      (_, i) =>
        [
          "Cell Biology lecture — School · 10:00–11:20 AM",
          "Design studio and collaborative project workshop with an unusually long course title — University shared calendar · 12:00–2:00 PM",
          "Chemistry tutorial — School · 2:30–3:20 PM",
          "History seminar — School · 4:00–5:00 PM",
          "Evening studio — Personal · 6:00–7:00 PM",
          "Keep everything as it is",
        ][i],
    ),
  };
}

if (["sign-in", "onboarding"].includes(scenario ?? "")) {
  const signedIn = scenario !== "sign-in";
  preview.auth = {
    required: true,
    signedIn,
    phase: signedIn ? "signedIn" : "signedOut",
    busy: false,
    onboarded: false,
    googleEnabled: true,
    signInProvider: "google",
    aiSetupConfirmed: false,
    email: signedIn ? "alex@example.invalid" : undefined,
  };
  preview.waitingApproval = false;
  preview.messages = [];
  preview.proposals = [];
  preview.canApprove = false;
}

if (scenario === "web-calendar-sync") {
  preview.page = "settings";
  preview.settingsSection = "calendars";
  preview.auth = {
    required: true,
    signedIn: true,
    onboarded: true,
    phase: "signedIn",
    busy: false,
    googleEnabled: true,
    email: "casey@example.invalid",
  };
  preview.waitingApproval = false;
  preview.running = false;
  preview.calendars = [
    {
      id: "fixture-school",
      title: "School",
      sourceName: "iCloud",
      provider: "apple",
      direct: false,
      unavailable: false,
      isReadOnly: false,
    },
    {
      id: "fixture-personal",
      title: "Personal",
      sourceName: "iCloud",
      provider: "apple",
      direct: false,
      unavailable: false,
      isReadOnly: false,
    },
    {
      id: "fixture-long",
      title:
        "A shared calendar with a long name for accessibility and layout verification",
      sourceName: "iCloud",
      provider: "apple",
      direct: false,
      unavailable: false,
      isReadOnly: true,
    },
  ];
  preview.webCalendarSync = {
    busy: false,
    sourceKeys: {
      "fixture-school": "school",
      "fixture-personal": "personal",
      "fixture-long": "long",
    },
    mirrors: [
      {
        id: "fixture-mirror",
        sourceKey: "school",
        generation: "fictional",
        enabled: true,
        name: "School",
        syncedAt: "2026-10-20T14:00:00Z",
        complete: false,
        error: "Calendar access was lost. The previous web copy is kept.",
      },
    ],
  };
}

if (["friends", "friends-empty", "friends-error", "friends-batch"].includes(scenario ?? "")) {
  preview.native = true;
  preview.page = "settings"; preview.settingsSection = "friends";
  preview.auth = { required: true, signedIn: true, onboarded: true, phase: "signedIn", busy: false, googleEnabled: true, email: "sam@example.invalid" };
  preview.running = false; preview.saving = false; preview.waitingApproval = false; preview.proposals = []; preview.messages = [];
  preview.sharing = { loaded: true, busy: false, token: "preview", sources: [], shares: scenario === "friends-empty" ? [] : [
    { id: "55555555-5555-4555-8555-555555555555", ownerID: "22222222-2222-4222-8222-222222222222", recipientID: "11111111-1111-4111-8111-111111111111", outgoing: false, personName: "Riley Morgan", email: "riley@example.invalid", permission: "titles", status: "pending", expiresAt: "2026-10-28T00:00:00Z", calendars: [{ id: "33333333-3333-4333-8333-333333333333", name: "Studio workshops, portfolio reviews and community events", syncedAt: "2026-10-21T00:00:00Z", stale: false }] },
    { id: "66666666-6666-4666-8666-666666666666", ownerID: "77777777-7777-4777-8777-777777777777", recipientID: "11111111-1111-4111-8111-111111111111", outgoing: false, personName: "Jordan Lee", email: "jordan@example.invalid", permission: "busy", status: "accepted", expiresAt: "2026-10-28T00:00:00Z", calendars: [{ id: "44444444-4444-4444-8444-444444444444", name: "Personal", syncedAt: "2026-10-20T12:00:00Z", stale: true, error: "Source Mac is offline. Previous sharing copy is kept." }] },
    { id: "88888888-8888-4888-8888-888888888888", ownerID: "11111111-1111-4111-8111-111111111111", recipientID: "22222222-2222-4222-8222-222222222222", outgoing: true, personName: "Riley Morgan", email: "riley@example.invalid", permission: "titles", status: "accepted", expiresAt: "2026-10-28T00:00:00Z", calendars: [{ id: "99999999-9999-4999-8999-999999999999", name: "School", syncedAt: "2026-10-21T00:00:00Z", stale: false }] }
  ], ...(scenario === "friends-error" ? { error: "Sharing couldn’t refresh. Check your connection and try again. Friend calendars haven’t been verified." } : {}) };
}

if (scenario === "friends-batch" && preview.sharing) {
  preview.calendars = Array.from({ length: 20 }, (_, i) => ({ ...preview.calendars[0], id: `fixture-source-${i}`, title: `Studio ${i + 1} — workshops, project reviews and community sessions` }));
  preview.sharing.shares[0].calendars = Array.from({ length: 20 }, (_, i) => ({ ...preview.sharing!.shares[0].calendars[0], id: `fixture-calendar-${i}`, name: `Studio ${i + 1} — workshops, portfolio reviews and community sessions` }));
}

if (["tasks", "tasks-empty", "tasks-error", "tasks-loading"].includes(scenario || "")) {
  preview.page = "tasks"; preview.messages = []; preview.proposals = []; preview.waitingApproval = false; preview.canApprove = false; preview.selectedCount = 0;
  preview.tasks = {token:"task-preview",loaded:scenario!=="tasks-loading",busy:false,deviceID:"preview-mac",items:scenario==="tasks-empty"?[]:Array.from({length:12},(_,i)=>({
    id:"task-fixture-"+i,version:"v1",title:["Finish the research methods assignment", "Outline the studio presentation", "Read chapter four and write discussion notes", "Submit the field report — include observations, illustrations and the full reference list"][i%4],
    dueDate:i%4===2?undefined:"2026-11-"+String(1+i).padStart(2,"0"),dueTime:i%3===0?"17:00":undefined,timeZone:"America/Toronto",notes:"Fictional task for isolated UI verification.",completed:i===10,deleted:i===11,rank:i,updatedAt:"2026-10-22T12:00:00Z",calendarID:i%4===2?undefined:"google",calendarName:i%4===2?undefined:"Personal",...(i===3?{calendarError:"The calendar could not be reached. Your task is saved; review and try again."}:{}),...(i===0?{reminderMinutes:60,reminderDeviceID:"preview-mac"}:{}),
  }))};
  if (scenario==="tasks-error") preview.tasks.error="Tasks couldn’t sync. Local changes are kept. Try syncing again when connected.";
}

// Design preview: fictional task-only review, outcome and Settings permissions. No native bridge, no writes.
const previewPermissions = (): NonNullable<AppState["agentPermissions"]> => ({
  loaded: true, busy: false, revision: 0, expiresAt: null, limits: { perRun: 20, perWindow: 100, windowMinutes: 60 },
  families: [
    { id: "create", label: "Add tasks", detail: "Save tasks you ask for when they have no new calendar deadline.", enabled: false, expired: false },
    { id: "link", label: "Add calendar events to Tasks", detail: "Link an event you selected. The event itself is never changed.", enabled: false, expired: false },
    { id: "edit", label: "Edit tasks", detail: "Change a task’s title, date, time or notes.", enabled: false, expired: false },
    { id: "complete", label: "Complete or reopen tasks", detail: "Mark tasks done, or open them again.", enabled: false, expired: false },
    { id: "archive", label: "Archive or restore tasks", detail: "Move tasks out of your list, or bring them back.", enabled: false, expired: false },
  ],
});
preview.agentPermissions = previewPermissions();
export const previewTaskRows = (count: number) => Array.from({ length: count }, (_, i) => ({
  id: "preview-row-" + i,
  title: i % 3 === 0 ? "Submit the field report — include observations, illustrations and the full reference list" : "Read chapter " + (i + 1) + " and write discussion notes",
  note: i === 1 ? "Its linked calendar event isn’t changed." : null,
  changes: [{ label: "Status", before: "Open", after: "Complete" }],
}));
if (["task-review", "task-review-long", "task-review-link", "task-outcome", "task-outcome-partial", "task-permissions"].includes(scenario ?? "")) {
  preview.proposals = []; preview.waitingApproval = false; preview.canApprove = false; preview.selectedCount = 0;
  preview.messages = [{ role: "user", content: scenario === "task-review-link" ? "Add this event to Tasks" : "Mark my finished reading tasks complete." }];
  if (scenario === "task-review" || scenario === "task-review-long") {
    preview.running = true;
    preview.taskReview = { id: "preview-review", token: "preview-token", digest: "preview-digest", kind: "complete", phase: "waiting", calendarWrites: 0,
      reason: "No current permission for this action and invocation.", heading: scenario === "task-review" ? "Mark complete: 2 tasks" : "Mark complete: 12 tasks",
      rows: previewTaskRows(scenario === "task-review" ? 2 : 12) };
  }
  if (scenario === "task-review-link") {
    preview.running = true;
    preview.taskReview = { id: "preview-link", token: "preview-token", digest: "preview-digest", kind: "link", phase: "waiting", calendarWrites: 0,
      reason: "No current permission for this action and invocation.", heading: "Add this event to Tasks",
      rows: [{ id: "preview-link-row", title: "Studio critique and portfolio review", note: "Your calendar isn’t changed.", changes: [
        { label: "New task", after: "Studio critique and portfolio review" }, { label: "Event", after: "Fri, Nov 6, 2026 · all day" }, { label: "Linked to", after: "School" }] }] };
  }
  if (scenario === "task-outcome") preview.taskOutcome = { id: "preview-outcome", status: "saved", headline: "2 tasks updated", viaSavedPermission: true,
    rows: previewTaskRows(2).map((r) => ({ id: r.id, title: r.title, status: "saved" })) };
  if (scenario === "task-outcome-partial") preview.taskOutcome = { id: "preview-outcome", status: "partial", headline: "1 of 3 saved", viaSavedPermission: false,
    rows: [{ id: "a", title: "Read chapter 1", status: "saved" }, { id: "b", title: "Read chapter 2", status: "failed", message: "Finish or skip this task’s deadline review first." }, { id: "c", title: "Read chapter 3", status: "cancelled", message: "Stopped before this change was saved." }] };
  if (scenario === "task-permissions") { preview.page = "settings"; preview.settingsSection = "privacy"; }
}
