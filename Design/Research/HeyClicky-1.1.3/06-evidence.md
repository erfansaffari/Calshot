# Evidence and open questions

## Target

- App: `/Applications/HeyClicky.app`. macOS version **1.1.3**, build **71**, bundle ID `com.humansongs.clicky`, build resource commit `bb70d07c3`, signature Team ID `2UDAY4J48G`.
- Executable: signed universal Mach-O with arm64 and x86_64 slices. The executable SHA-256 was `10da0d2641c6d235a57e8b4f2388bcb029e8282aca996f644e264fc6db97e512`. This study inspected the arm64 slice. The older DMG was excluded from architectural conclusions in this report.
- Rea 6.9.0 identified the executable and opened the app bundle in the earlier pass. It reported no configured native analysis provider for function-level inspection. This report uses Mach-O Swift nominal type/field descriptors, framework and imports metadata, packaged code/configuration and official release notes. Static metadata establishes the presence of a type or capability, with call order inferred only where several sources agree.
- A packaged spatial demo was inspected frame by frame at one-second intervals. It shows a mark over an anatomy image. No live app state was observed, no private settings or user files were opened, and no account or service requests were made.

## Local source anchors

Paths point to the installed app. Recheck the hashes after an update, since the app can replace these files.

| Evidence | Anchor | Purpose |
| --- | --- | --- |
| E1 | [Drawing engine](/Applications/HeyClicky.app/Contents/Resources/clicky-draw-engine.js:189) | Program execution, statement boundaries, streaming, editing |
| E2 | [Native Canvas bridge](/Applications/HeyClicky.app/Contents/Resources/clicky-draw-native.js:637) | Native canvas API, feed, speech line and duration events |
| E3 | [Drawing library](/Applications/HeyClicky.app/Contents/Resources/clicky-draw-pieces.js:1) | Drawing helpers and host-owned controls |
| E4 | [Figure implementation](/Applications/HeyClicky.app/Contents/Resources/clicky-draw-engine.js:512) | Figure, layers, named geometry parts and per-frame pose |
| E5 | [3D kernel](/Applications/HeyClicky.app/Contents/Resources/clicky-three-parts.js:1) | Separate context, Three.js geometry recipes and typed arrays |
| E6 | [Bundled Three.js](/Applications/HeyClicky.app/Contents/Resources/clicky-three.js:1) | Version and dependency attribution |
| E7 | [Codex model catalog](/Applications/HeyClicky.app/Contents/Resources/ClickyCodexModelCatalog.json) | Agent model menu metadata and effort |
| E8 | [Job model guidance](/Applications/HeyClicky.app/Contents/Resources/ClickyModelInstructions.md) | Workspace continuity and progress instructions |
| E9 | [Browser skill](/Applications/HeyClicky.app/Contents/Resources/ClickyBundledSkills/clicky-browser/SKILL.md) | Browser, connector and public-web surface selection |
| E10 | [Official changelog](https://www.heyclicky.com/changelog) | Vendor descriptions for 1.1.1, 1.1.2 and 1.1.3, with older/later versions explicitly distinguished |
| E11 | [Selected Swift type and field evidence](evidence-swift-types.txt) | App, job, renderer and notebook state |
| E12 | [Local resource hashes](evidence-sha256.txt) | Build-specific resource fingerprints |

## Distinctions that matter

- **Direct code evidence.** The shipped JavaScript implements incremental drawing, the native canvas bridge and the procedural Three.js geometry primitives. This establishes much more than a class-name match.
- **Binary metadata.** The installed binary holds native types for notch, voice, objects, jobs, permissions and note versions. This establishes the shipped architecture boundaries. It does not ensure every path is enabled or expose all branches and thresholds.
- **Product description.** Release notes support high-level behavior and which version introduced it. Some notes describe behavior that changed later. No later release behavior was imported into the 1.1.3 conclusions.

## Remaining unknowns by area

| Area | Open question |
| --- | --- |
| Voice | Exact backend model/router combination for a fresh installed session, fallback order, and actual time to first audio |
| Notch | Exact presenter precedence, panel frame changes during transitions, and observed focus behavior across displays |
| Agents | Default harness/place selection, storage/lease behavior after loss of connectivity, and which note writing path is active |
| Computer use | Actual call sequence and runtime enforcement of consent, stop, and scope boundaries |
| 3D lessons | Interaction math, resource bounds across a full scene, and which types of explanation are recorded by default |
| Ink | Complete document grammar, which Ink surfaces are enabled for the installed account, and whether notebook writing shares a clock with any narration path |

The most direct evidence for a specific model would be a model identifier surfaced by a fresh benign turn in the app itself. Bundle strings and menu options cannot substitute for that observation.
