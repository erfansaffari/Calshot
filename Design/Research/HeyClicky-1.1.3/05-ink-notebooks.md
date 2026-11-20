# Ink notebooks and live writing

The installed binary contains a document system called **Clicky Ink**. Its data model, renderers and animation state are separate from the over-screen drawing engine. The app also has an expanded chat reading surface with its own Markdown renderer and a drawing lesson viewer. A paper-looking drawing card, an Ink note and a Markdown chat reply are three different surfaces.

## The note pipeline

| Stage | Build evidence | Meaning |
| --- | --- | --- |
| Write | `AgentHarnessTurnContext` carries a note path and a note-writing capability flag. `ClickyInkBrief.NoteWriter` names patch, file and note-tool modes. | The agent can be given a dedicated artifact to update during a job. Which mode a given job receives is unverified. |
| Publish | Harness events include note preview and note saved. `ClickyInkNoteStore` has watched paths, a stat record with time and size, a timer, a write queue and a revision. | The client can present progress from both events and evolving note files. Exact precedence between those sources remains unknown. |
| Track versions | `ClickyInkNoteVersion` carries timestamp, text, edit, partial and new-edit flags. The store tracks versions per note ID, current documents, live notes, settled notes and kept notes. | A partial working draft can remain distinguishable from a completed document. |
| Build a structured page | `ClickyInkDocument` contains titled pages with blocks. Dashboard state contains sections, groups, sources, answer and change state. There is also a front-page adapter with columns, story chunks and overflow. | An agent's content is rendered by application-owned views with layouts the client understands. The study did not recover the complete parser or the on-disk grammar. |
| Animate the changes | `ClickyInkLiveNote` tracks page, block, item and word segments with arrival and removal times. Segments can contain written, struck, edited or preview state. `ClickyInkPenSchedule` and `ClickyInkPenRenderer` have scheduling and clock state. | The apparent handwriting can evolve from document versions. Stable blocks can remain while the pen works through new or changed content. |
| Act and revisit | Note targets are a Clicky or a job. Actions include ask, answer, send and review. There is a persistent answer/feedback store and an action interface for paths, routines and follow-ups. | An Ink page can be more than a passive result, with typed interactions routed back to application state. These type names do not prove authority or permission handling. |

## What the screens can represent

- **Documents.** Typed blocks include headings, answers, prose, notes, lists, checklists, tables, code, figures, sources, questions, progress and status. There are specialized native blocks for tickets, receipts, photos and links.
- **Interactive pages.** The executable contains views for forms, quizzes, questions, galleries, charts and review lists. The model contains IDs and action objects to associate a response with the originating item. Presence in the binary does not establish which blocks were exposed to this account.
- **Page layout.** The built-in layouts include desk, edition and front-page presentation, with a dashboard variant and an editorial column planner. Metadata exposes scroll/camera state, a window silhouette, row motion and per-block writing state. No pixel-perfect layout was reconstructed.
- **Sketches.** The Ink sketch model recognizes shapes, paths, arrows, text and badges and has its own painter. The separate 3D renderer is verified in the screen-drawing stage. There is no evidence in this pass that an Ink figure block uses that same Metal stage.

## Does it write and talk at the same time?

There are two related effects with different evidence.

1. **Draw while speaking.** This is directly supported by shipped renderer code. The same response can contain speech beats and drawing marks, and the canvas uses line playback events to schedule those marks. A native 3D stage can appear as part of that explanation. [Drawing, 3D, and narration](04-drawing-3d-and-narration.md)
2. **Write in a notebook while the assistant speaks.** The notebook has its own revision and pen clock. Separately, job reports can speak aloud, raise a heads-up or play a cue. These components can account for a working page and spoken status appearing together. The local evidence does not establish a word-by-word narration link or a single clock between an Ink page and speech. It could be independent presentation of job progress and a spoken report.

HomeSpace chat separately parses styles such as prose, code, charts, checklists, tables and sources. Its streaming-tail and layout-cache fields are consistent with readable formatted replies as they arrive. That interface could look notebook-like without using the Ink pen system. [UI and notch](01-ui-and-notch.md)
