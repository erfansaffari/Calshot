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
