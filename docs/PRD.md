# Minutes: PRD

> Working name. A free, local-first **Granola alternative** for macOS and iOS. On-device transcription (Parakeet), true speaker diarization, calendar-aware participants, drag-to-assign speakers, voiceprints that learn over time, local summaries, and pluggable exports (Markdown, Parachute vault, Google Docs, …).

## 1. Problem
Granola-style tools are great at "record without a bot, get good notes". But they:
- **send audio and transcripts to the cloud**,
- **cost a monthly subscription**,
- label speakers as **"Me / Them"** instead of real names, and forget who people are between meetings,
- lock your notes into their app or a few integrations.

Meetily is open source and local, but has no iOS app, keeps diarization in its paid edition, and has no persistent speaker identity.

I want a tool that knows who was in the meeting (from my calendar), knows what each of those people sounds like (it learns once and remembers), runs entirely on my devices, and pushes finished notes wherever I keep knowledge (my Parachute vault first).

## 2. Goals and non-goals
### Goals (v1)
1. **G1. Local-first:** audio, transcripts, embeddings and summaries are processed on device by default. Cloud LLMs are opt-in and BYO-key.
2. **G2. Calendar-aware:** pulls upcoming meetings and attendees (names + emails) and prompts to record when a meeting starts.
3. **G3. Real speaker names:** diarization, plus an **easy assignment UI** (drag attendee chips onto speaker cards, with audio snippets to confirm).
4. **G4. Persistent voiceprints:** assigned speakers enrol voice embeddings. Future meetings auto-identify known people, especially calendar attendees.
5. **G5. Review → finalize → export:** lock speakers, produce the final transcript + summary (templated), and export through adapters.
6. **G6. macOS and iOS:** Mac captures calls (mic + system audio). iPhone captures in-person meetings (mic). Same data model, same voiceprint library.

### Non-goals (v1)
- Meeting bots that join Zoom/Meet.
- Windows/Linux/Android.
- Real-time collaboration and sharing links (exports cover sharing).
- Cloud sync service. v1 may sync through iCloud (CloudKit private DB) in phase 6; no custom server ever.
- Live AI coaching during the meeting.

## 3. Personas
| Persona | Needs |
|---|---|
| **Me (primary):** many calls/day, Parachute vault user | Zero-friction capture, accurate names, notes land in my vault linked to person notes |
| **Privacy-sensitive professional** (lawyer, therapist, consultant) | Nothing leaves the device; clear consent tools |
| **In-person meeter** | iPhone on the table records; speakers identified afterwards |

## 4. Core user flows
### F1. Onboarding
Grant microphone permission → system-audio permission (Mac) → calendar access (EventKit) → model download (Parakeet + diarization, ~700 MB, with progress) → **enrol my own voice** (read a 20-second paragraph; creates the "Me" profile) → pick default export destinations (e.g. Parachute vault + Markdown folder) → pick the summary engine (Apple on-device by default).

### F2. Meeting starts (Mac)
1. Minutes sees a calendar event starting (±2 min) **or** detects the mic in use by a meeting app.
2. A notification appears: **"Weekly sync with Ana & Raj — Start recording?"** [Record] [Not this one].
3. When recording, a menu-bar indicator and a small floating window show a timer, live transcript (optional), a **notes pad** (Granola-style user notes) and a "bookmark" button.
4. Meeting ends (calendar end + mic released, or manual Stop) → processing starts automatically.

### F3. Meeting (iPhone)
Notification at event start, or open the app → **Record** → Live Activity on the Lock Screen / Dynamic Island with timer and stop. Recording continues in the background. Processing runs on the phone (or is deferred to the Mac if the phone is low on battery, phase 6).

### F4. Review speakers (the signature screen)
- Left: **speaker cards** from diarization ("Speaker A — 12m 40s — ▶ sample 1 ▶ sample 2 ▶ sample 3"). Cards that were auto-identified show the person's name plus a confidence indicator (✓ high / ? suggested).
- Top: **attendee chips** from the calendar event (name, email, avatar). Plus "Me", plus "+ Someone else" (search the people library or create one).
- The user **drags a chip onto a card** (or clicks the card → picks from the list). Merge cards (drag a card onto a card) when diarization split one person in two. Split isn't in v1, but "reassign this segment" is available in the transcript.
- The transcript preview updates live with names.
- **Lock speakers** → saves assignments and enrols/updates voiceprints (opt-in per person; default on for calendar attendees).

### F5. Finalize and export
- Generate the summary with a template (General, 1:1, Standup, Interview, Sales/Customer call, Custom). It merges the **user's notes** + transcript (Granola-style enhance).
- Review/edit the summary (Markdown editor). **Finalize** → runs the configured export adapters → shows per-adapter status (✓ Parachute, ✓ Markdown, ⚠ Google Docs re-auth needed).

### F6. Library
List of meetings (search across transcripts, filter by person), **People** view (each person: email(s), meetings, voiceprint status with re-enrol/delete), re-export, delete meeting (deletes audio by default after N days, configurable).

## 5. Functional requirements
Priority: **P0** = MVP (Mac), **P1** = v1, **P2** = later.

| ID | Requirement | Pri | Acceptance criteria |
|---|---|---|---|
| MN-FR-01 | Record mic and system audio on macOS as **separate tracks** (48 kHz) | P0 | Zoom/Meet call: both sides captured. The "Me" track has no remote voices (headphones) or little bleed |
| MN-FR-02 | Crash-safe recording (CAF/WAV chunks flushed every 5 s; resume on relaunch) | P0 | Killing the app loses ≤ 5 s |
| MN-FR-03 | Batch transcription with Parakeet Ultra (or v3) via FluidAudio, word timestamps | P0 | 60-min meeting processed in < 2 min on M1+; WER comparable to Parakeet Ultra benchmarks (2.13% clean) |
| MN-FR-04 | Offline diarization (FluidAudio VBx) on the system track; mic track = "Me" (with VAD); for mic-only recordings, diarize the mic track | P0 | 4-speaker test set DER < 20%; "Me" correctly attributed > 95% of the time on Mac calls |
| MN-FR-05 | Merge ASR words + diarization into speaker-attributed utterances | P0 | No word lost; utterances split at speaker changes |
| MN-FR-06 | EventKit calendar integration: upcoming events, attendees (name, email, self), conference link detection | P0 | Event with 3 Google attendees shows 3 chips with names/emails |
| MN-FR-07 | Speaker review UI: cards with playable samples, drag-assign, merge, reassign a segment | P0 | Assign 3 speakers in < 30 s |
| MN-FR-08 | People library with emails, display name derivation (EventKit name → Contacts → heuristic) | P0 | `ana.lopez@acme.com` with no name → "Ana Lopez" |
| MN-FR-09 | Voiceprint enrolment on lock; auto-identification for future meetings, attendees prioritized | P1 | Second meeting with the same people: ≥ 90% of speakers auto-labelled correctly, < 2% wrong-name rate at the default threshold |
| MN-FR-10 | Summary generation with templates; user notes merged; pluggable LLM providers (Apple Foundation Models, MLX local, Ollama/OpenAI-compatible, BYO cloud key) | P0 (one provider) / P1 (all) | 60-min transcript → summary with decisions, action items (with owners), topics |
| MN-FR-11 | Export adapters: Markdown folder (Obsidian-style front matter), **Parachute vault** (meeting note + person links), JSON | P0 | Note appears in Parachute tagged `meeting`, linked to person notes via `attended-by` |
| MN-FR-12 | Export adapter: Google Docs (OAuth, `drive.file` scope) | P1 | Doc created with headings and transcript via HTML multipart upload |
| MN-FR-13 | Export adapters: Webhook (POST JSON), Shell command, Notion | P2 | — |
| MN-FR-14 | Meeting start prompts (calendar + mic-in-use detection) on Mac | P1 | Notification within 30 s of a call starting |
| MN-FR-15 | Live transcript during recording (Parakeet EOU streaming, English) | P1 | Latency < 2 s |
| MN-FR-16 | Notes pad during recording + bookmarks (timestamps) merged into the summary | P1 | Bookmarked moments appear as timestamped items |
| MN-FR-17 | iOS app: record (mic), background + Live Activity + AudioRecordingIntent, process on device, review, export | P1 | 60-min in-person meeting recorded with the screen locked |
| MN-FR-18 | Sync between Mac and iPhone of people/voiceprints/meetings (CloudKit private DB, optional) | P2 | Person enrolled on Mac auto-identified on iPhone |
| MN-FR-19 | Search across transcripts and chat-with-meetings (local RAG) | P2 | — |
| MN-FR-20 | Optional Google Calendar API provider (BYO OAuth client) for users without the Google account in Apple Calendar | P2 | — |
| MN-FR-21 | Consent helpers: optional "recording" message snippet to paste in chat; per-meeting retention policy | P1 | — |
| MN-FR-22 | Import an existing audio file (e.g. Handy/voice memo/Zoom recording) and process it | P0 | Drop a WAV → full pipeline |

## 6. Non-functional requirements
| ID | Requirement |
|---|---|
| MN-NFR-01 Privacy | No network calls except model downloads, the user-configured LLM/export endpoints and calendar. No analytics. Voiceprints stored encrypted at rest (Data Protection on iOS; file in a sandboxed container; optional Keychain-wrapped key). |
| MN-NFR-02 Performance | Post-processing a 60-min meeting on an M1: ASR < 90 s, diarization < 60 s, summary < 60 s (Apple FM). iPhone 15 Pro: total < 6 min. |
| MN-NFR-03 Platforms | **macOS 15+** (FluidAudio offline diarization crashes on macOS 14), **iOS 18+**. Apple Foundation Models summaries need 26+; fallback providers otherwise. |
| MN-NFR-04 Storage | Audio stored as AAC 64 kbps per track after processing (originals optional). Retention configurable. |
| MN-NFR-05 Reliability | Pipeline steps idempotent and resumable; a failed export never loses the meeting. |
| MN-NFR-06 Licensing | App is MIT. Models: Parakeet (CC-BY-4.0), pyannote/WeSpeaker conversions (MIT/Apache) — include attributions. |

## 7. Success metrics
- I use it for all my meetings for 2 weeks instead of Granola.
- ≥ 90% of known speakers auto-identified after their second meeting, < 2% wrong-name rate.
- Notes land in Parachute linked to the right people with no manual editing in ≥ 80% of meetings.

## 8. Open questions for the owner
1. **Parachute data model (Standardized):** Confirmed matching Prism convention: meeting notes at `vault/meetings/<YYYY-MM-DD>/<slug>` (tag `meeting`), person notes at `vault/people/<slug>` (tag `person`), linked via relationship `attended-by`.
2. **Audio retention default:** keep forever, 30 days, or delete after finalize? *Default: 30 days.*
3. **Summary default engine:** Apple on-device (needs macOS 26) vs local MLX model vs your Claude key? *Default: Apple FM if available, else MLX Qwen3-4B.*
4. Should voiceprint enrolment for others be **opt-in per person** (privacy) or automatic? *Default: automatic for calendar attendees, with a per-person delete.*
5. Final name.
