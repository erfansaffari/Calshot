# Calshot as a personal, proactive agent

Status: owner direction, 2026-11-11. This plan supersedes the voice review rules in [VOICE_AGENT_PLAN.md](VOICE_AGENT_PLAN.md) and the "suggestions the user approves" memory rule. Swift still owns every write, receipt and the permission kernel; this plan changes *when* the user is asked, not *who* executes.

## Direction

Calshot is no longer only a calendar agent. It is a personal agent on the Mac that you talk to (like Clicky / HeyClicky: voice, screen-aware, next to the cursor), that knows you, and that eventually tells you what to do next before you ask. The calendar and tasks are the first things it can act on.

Three principles:

1. **Voice acts.** A spoken request is done, not reviewed. When something essential is missing, Calshot asks aloud and the user answers aloud. The notch and the app show what was done, with **Undo** on every change. No approve buttons in voice.
2. **Calshot learns.** Everything the user says, how they react, and their calendar build a personal knowledge base that is added to, reinforced, corrected and forgotten over time. It shapes how Calshot talks and what it assumes.
3. **Calshot anticipates.** Once it knows the user, it notices what is coming, what is at risk and what usually happens next, and offers to do it.

## 1. Voice acts (phase 1 — in progress)

| Situation | Before | Now |
| --- | --- | --- |
| Month/day without a year (spoken *or* on screen) | year review | next occurrence, never asked |
| Start time but no end time | review | learned typical duration for that kind of event, else 1 hour |
| No time and not all-day | review | asked aloud ("What time?") |
| Several events match an edit/delete | review card | asked aloud with the distinguishing date/time |
| Same event already on the calendar | review | said aloud, nothing written |
| Task create/edit/complete/archive | always reviewed in voice | saves under Autonomy, like typed requests |
| Guests or a repeating series | review | still a review for now (saving notifies other people / changes many events; phase 2 adds spoken confirmation) |

What the user sees: a **"Done"** list in the notch and in the app (each saved change with title, time, calendar and **Undo**). Undo is a native reverse change built from the receipt; clicking it is the user's explicit request.

## 2. Context engine (phase 1 foundation, phase 2 depth)

The context engine turns signals into a small, ranked, *current* picture of the user that every agent turn (typed, voice, screenshot) receives.

### Signals → knowledge

| Source | How it is captured | Example knowledge |
| --- | --- | --- |
| What the user says | `remember` / `forget_memory` tools during the conversation; saved immediately, visible in Settings | "Calls the gym session 'leg day'", "Prefers meetings after 10" |
| Conversation reflection | after a voice session (or typed run with ≥2 turns), one model pass proposes add / reinforce / update / forget operations; native code applies them with dedupe and tombstones | "Has a sister named Mina", "Is studying for the GMAT" |
| Behavior | native counters, no model: interruptions while Calshot speaks, repeated corrections, cancelled actions, time of day of use | "Keep spoken replies to one sentence" (after interruptions) |
| Calendar | native profile over the last 8 weeks and next 4 weeks of the user's own calendars | routines (weekday + time), typical durations per kind of event, usual day start/end, frequent places, busy days ahead |

Added 2026-11-13:

| Source | How it is captured | Example knowledge |
| --- | --- | --- |
| Identity | account display name and email, else the Mac user name; sent with every request | "name: …" |
| Calendar conclusions | the reflection reads the calendar profile; a separate pass runs when the set of repeated titles changes (at most once a day) | "Is a university student, likely statistics and computer science" |
| Screen | text recognized on screen during a voice session is evidence for the end-of-session reflection; source `screen`, confidence ≤ 0.7, expires unless seen again, never synced | "Is working on a compiler project" |
| Conversation notes | each reflection writes a 1–3 sentence dated note of the conversation (200 kept, device-only, forgettable in Settings → Memory) | "Asked about Monday and added a task to text Martin, due 9:00" |

Reflection now also runs after typed requests (not screenshot runs). Chat turns are timestamped, and history includes clipped results of what Calshot did.

### Memory model

Each item has kind (`preference`, `fact`, `person`, `routine`, `style`, `goal`), text, **source** (`user`, `conversation`, `behavior`, `calendar`), **confidence**, **evidence count**, last seen, optional expiry, and `supersedes` when it replaced an older item. Rules:

- *Invalidate, don't silently overwrite*: an update keeps a tombstone of the old text so a forgotten or corrected fact is never re-learned from retained history.
- Learned items are active immediately but are always visible, editable and forgettable in Settings → Memory, with their source.
- Repetition reinforces (evidence count, confidence); contradiction supersedes; low-confidence inferred items expire if never reinforced.
- Memory is context, never authority: it never grants a write, never fills a date the user did not give, and shared-friend calendar content never enters it.
- Retrieval is just-in-time and budgeted: style and high-confidence preferences always; other items by relevance to the current turn.

### Behavior adaptation

- An interruption while Calshot is speaking immediately tells the live voice session to shorten; the count also persists, and after repeated interruptions a `style` memory makes short replies the default in future sessions.
- The same mechanism will cover: preferring numbers vs. relative times, asking vs. assuming, language.

### Storage and sync (built 2026-11-12; server-readable, chosen by the owner)

- **On the Mac (the fast path):** the account's knowledge file is what every request reads — in memory, no network on the hot path.
- **In Supabase (the account copy):** `supabase/migrations/20261112090000_personal_knowledge_sync.sql` adds one row per item (`personal_knowledge`) and SHA-256 tombstones for forgotten text (`personal_knowledge_tombstones`), owner-only through RLS, written only through validating RPCs (`read_/write_/clear_personal_knowledge`). Newer copy wins per item; deletes travel as rows without text; the same knowledge learned on two Macs keeps the copy with the smaller id everywhere. Behavior counters and the calendar profile stay on each device.
- **App:** `Sources/Memory/KnowledgeSync.swift` syncs with the 30-second account sync (read, merge, then send), on by default for signed-in accounts, with a Settings → Memory switch and "Remove synced copy". Until the migration is applied the app says sync isn't set up yet and keeps everything local.
- Verified: SQL authorization test on Postgres 17 (`supabase/tests/personal_knowledge_authorization.sql`), merge-rule unit tests. Not yet verified against the live project.
- Still to do: encrypt the local file with a Keychain key.

## 3. Proactive agent (phase 3)

Built on the context engine and the existing proactive planning plan ([PROACTIVE_PLANNING_IMPLEMENTATION.md](PROACTIVE_PLANNING_IMPLEMENTATION.md)):

- **Triggers:** start of day, before a meeting (travel/prep), conflicts and double bookings, deadline risk, a routine that did not happen, a new email/screen item that looks like an event (opt-in).
- **Surface:** one notch suggestion at a time, spoken only when voice is active; "Do it" by click or voice, dismiss, snooze. Dismissals are a behavior signal and lower that trigger's priority.
- **Limits:** quiet hours, a daily cap, dedupe, never a burst after sleep. Proactive *actions* run only after the user accepts the suggestion (accepting is the request); background writes still do not exist.

## 4. Beyond calendar (phase 4)

Screen-aware help ("what is this", "walk me through this"), pointing and drawing, and background agents for research and small tasks, using the same knowledge and the same one ongoing conversation.

## Phase 1 deliverables and checks

- Native: voice draft resolution (year, default duration), spoken clarification results instead of reviews, voice task autonomy, memory schema v2 with sources/confidence, `forget_memory`, behavior signals, calendar profile, post-session reflection, native undo command.
- Bridge/UI: recent changes with Undo in the notch and the app; memory list shows source.
- Tests: draft mapper voice mode, executor spoken clarification, memory v1 → v2 decoding and reinforcement, behavior style derivation, calendar profile, reflection application, undo command validation. Full native suite and WebUI suite.
- Not in phase 1: spoken confirmation for guests/series, consolidation job, proactive triggers.

## Research notes

- HeyClicky / Clicky: Mac companion beside the cursor that sees the screen, answers by voice and can draw on screen; 2.0 adds background agents.
- Mem0 (2026): moved its default write path to one ADD-only extraction call because LLM-chosen UPDATE/DELETE erased details; updates/deletes remain explicit operations. Calshot applies the lesson: the reflection pass may propose updates and forgets, but native code applies them conservatively (supersede with tombstone, forget only inferred items unless the user said so).
- Memory-system guidance (context-engineering-collection skill): start with structured file memory, track temporal validity, consolidate periodically, load just in time, decay stale facts.
