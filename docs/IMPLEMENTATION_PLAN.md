# Minutes: Implementation Plan

Ordered by risk, with a headless-first approach: build and test the whole pipeline in `MinutesKit` + `minutes-cli` before any UI.
Task IDs (`MN-x.y`) are mirrored in [`../STATUS.md`](../STATUS.md). Each task fits one agent session and has a Definition of Done (DoD).

```mermaid
flowchart LR
  P0["P0 Spikes"] --> P1["P1 Headless pipeline (CLI)"]
  P1 --> P2["P2 Mac capture + app shell"]
  P2 --> P3["P3 Review UI + people + voiceprints"]
  P3 --> P4["P4 Summaries + exports (Mac MVP)"]
  P4 --> P5["P5 Calendar prompts, live transcript, polish (Mac v1)"]
  P5 --> P6["P6 iOS app"]
  P6 --> P7["P7 Sync + search + extras"]
```

---

## Phase 0: Spikes (code under `spikes/`; the outputs are reports in `docs/research/`)

| ID | Task | DoD |
|---|---|---|
| **MN-0.1** | **FluidAudio end-to-end on a file.** A Swift CLI: Parakeet TDT v3 ASR (word timestamps, long-file handling) + `OfflineDiarizerManager` + embedding extraction on (a) a Handy recording, (b) a 3–4 speaker AMI/VoxConverse clip. Record the API surface, memory, timings on this Mac, and whether diarization accepts min/max speaker hints. | `spike-mn01-fluidaudio.md` with code snippets, timings, DER/WER estimates, API notes |
| **MN-0.2** | **macOS dual capture.** Core Audio process tap (global, excluding self) + AVAudioEngine mic → two CAF files with a shared host-time anchor. Test with a Zoom/Meet call on speakers and on headphones. Measure bleed and alignment. | `spike-mn02-capture.md`; working sample code; permission strings |
| **MN-0.3** | **Speaker-ID calibration.** Using FluidAudio WeSpeaker embeddings on ≥ 20 speakers × multiple sessions (VoxCeleb test / AMI / own recordings): same-vs-different cosine distributions, pick `T_auto`, `T_suggest`, margin, min speech seconds. Evaluate cluster-centroid vs. per-segment max. | `spike-mn03-speakerid.md` with an ROC chart and recommended thresholds; ARCHITECTURE §6 updated |
| **MN-0.4** | **Mic bleed handling.** Compare (a) embedding-based reassignment of mic segments vs (b) LocalVQE AEC with the system track as reference vs (c) nothing, on a speakers-not-headphones call. | Recommendation in `spike-mn04-bleed.md` |
| **MN-0.5** | **Summaries.** Apple Foundation Models (if macOS 26 available) vs MLX Qwen3-4B vs Ollama on a 60-min transcript using map-reduce. Measure quality (manual rubric), latency, memory. | `spike-mn05-summaries.md` with default provider decision |

**Gate:** update ARCHITECTURE.md + DECISIONS.md with the results.

---

## Phase 1: Headless pipeline (`MinutesKit` + `minutes-cli`)

| ID | Task | Depends | DoD |
|---|---|---|---|
| MN-1.1 | Create the `MinutesKit` package (macOS 15 / iOS 18, Swift 6 strict concurrency), module targets, test targets, swift-format config, GitHub Actions (macos-15, `swift test`) | — | `swift build && swift test` green in CI |
| MN-1.2 | `MinutesCore` models + GRDB store + migrations (schema in ARCHITECTURE §3) + FTS5 | 1.1 | CRUD + migration tests |
| MN-1.3 | `MinutesSpeech`: ASRService, VADService, DiarizationService, EmbeddingService wrappers over FluidAudio (model download/cache, progress) | 1.1, 0.1 | Integration test on fixture (skipped in CI without models; `MINUTES_MODELS=1`) |
| MN-1.4 | Merger: words + diarization segments → utterances; "Me" channel handling | 1.3 | Unit tests on synthetic data incl. overlaps/ties |
| MN-1.5 | Pipeline orchestrator actor with persisted steps, resume, artifacts, progress stream | 1.2, 1.4 | Kill mid-run → resume completes; tests |
| MN-1.6 | `minutes-cli`: `import <file>`, `process <id>`, `show <id> [--json]`, `people`, `calibrate <dir>` | 1.5 | Running `minutes-cli import ~/…/handy-1791911766.wav && process` prints a transcript |
| MN-1.7 | `MinutesSpeakerID`: VoiceprintStore, SpeakerMatcher (Hungarian + thresholds), enrolment rules | 1.2, 0.3 | Unit tests with synthetic embeddings; CLI `assign <meeting> A=ana@x.com` + `lock` enrols |
| MN-1.8 | `MinutesCalendar`: EventKitProvider, ConferenceLinkParser, NameResolver (Contacts + heuristic), person upsert-by-email | 1.2 | Tests for the parser/resolver; CLI `events --today` lists attendees |

**Milestone M1:** CLI: import a multi-speaker file → transcript with clusters → assign names → second file auto-identifies the same people.

---

## Phase 2: Mac capture + app shell

| ID | Task | Depends | DoD |
|---|---|---|---|
| MN-2.1 | `Apps/project.yml` (XcodeGen) for MinutesMac + MinutesiOS targets, entitlements, Info.plist usage strings | 1.1 | Both apps build and launch empty |
| MN-2.2 | `MinutesCapture`: ChunkedAudioWriter (CAF segments, flush, index, crash recovery) | 1.1 | Tests: crash-recovery simulation |
| MN-2.3 | MicRecorder + SystemAudioTap (from spike 0.2), shared host-time anchor, device change handling | 2.2, 0.2 | Records a real call to 2 tracks for 60 min |
| MN-2.4 | Mac app: MenuBarExtra (record/stop, status), floating recorder panel (timer, notes pad, bookmark), onboarding (permissions, model download, "enrol my voice") | 2.1, 2.3 | Manual QA: record → pipeline runs automatically |
| MN-2.5 | Library window: meetings list, status/progress, transcript view with audio playback + click-to-seek, search (FTS) | 1.5, 2.4 | — |

## Phase 3: Review UI + people + voiceprints

| ID | Task | DoD |
|---|---|---|
| MN-3.1 | ReviewSpeakersView: speaker cards with 3 playable samples, attendee chips (from the meeting's calendar event), drag-assign, merge, keyboard shortcuts, "+ someone else" | Assign 3 speakers in < 30 s (manual) |
| MN-3.2 | Reassign a single utterance/segment in the transcript; live transcript name update | — |
| MN-3.3 | Lock speakers → enrol voiceprints, mark meeting ready for summary | Second meeting auto-labels (manual test with real calls) |
| MN-3.4 | People view: emails, meetings, voiceprint status, delete voiceprint, merge people, rename | — |
| MN-3.5 | Link meeting ↔ calendar event: auto-match by time overlap at record start; manual "pick event" for imports | — |

## Phase 4: Summaries + exports (Mac MVP)

| ID | Task | DoD |
|---|---|---|
| MN-4.1 | `MinutesSummarize`: LLMProvider protocol, template loader, map-reduce, structured JSON output | Unit tests with a fake provider |
| MN-4.2 | Default provider(s) from spike 0.5 (AppleFM and/or MLX) + OpenAICompat (Ollama/BYO key in Keychain) | Summary of a fixture transcript |
| MN-4.3 | Summary editor (Markdown) with regenerate/template switch; user notes + bookmarks merged | — |
| MN-4.4 | `MinutesExport` protocol, bundle, shared Markdown renderer + **MarkdownAdapter** | Golden file tests |
| MN-4.5 | **ParachuteAdapter** (people find/create, meeting upsert, attendee links, schema check, no-clobber option) | Mock-server tests + live test against localhost:1940 creates a linked meeting note |
| MN-4.6 | Finalize flow: run adapters, per-adapter status/retry, `export_run` history, re-export | — |
| MN-4.7 | Settings UI: adapters (multiple instances, Test connection), LLM provider, retention, templates folder | — |

**Milestone M2 (Mac MVP):** record a real call → review → finalize → linked note in Parachute + a Markdown file.

## Phase 5: Mac v1 polish
| ID | Task |
|---|---|
| MN-5.1 | MeetingDetector (calendar + mic-in-use + app detection) + actionable notifications + auto-stop suggestion |
| MN-5.2 | Live transcript preview (Parakeet EOU streaming) in the recorder panel |
| MN-5.3 | GoogleDocsAdapter (AppAuth PKCE, `drive.file`, HTML upload conversion, BYO client id) |
| MN-5.4 | Retention jobs (compress audio to AAC after finalize; delete after N days) |
| MN-5.5 | Consent helper snippet; per-meeting "don't enrol voices" toggle |
| MN-5.6 | Signing/notarization, Sparkle updates or GitHub releases, README/user guide |

## Phase 6: iOS app
| ID | Task |
|---|---|
| MN-6.1 | iOS recording (AVAudioSession, background audio, interruptions) + Live Activity with Stop intent |
| MN-6.2 | Event-start local notifications from EventKit; "Record" action opens the app and starts |
| MN-6.3 | On-device pipeline on iPhone (memory/thermal budget; process when charging option) |
| MN-6.4 | Shared review/people/summary views adapted to compact size (tap-to-assign instead of drag) |
| MN-6.5 | Exports on iOS (Parachute over Tailscale/LAN URL setting, Markdown to Files folder, Google Docs) |

## Phase 7: Later
- MN-7.1 CloudKit private-DB sync of people, voiceprints, meetings (audio optional).
- MN-7.2 Chat with meetings / cross-meeting search (local embeddings + RAG).
- MN-7.3 Webhook, Shell, Notion adapters; action items → Parachute tasks.
- MN-7.4 Google Calendar API provider (BYO OAuth client).
- MN-7.5 Share diarization/ASR engine with StudioLink transcripts (SL-6.2).
