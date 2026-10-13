# Minutes: Status

Legend: `[ ]` todo · `[~]` in progress (agent/session id) · `[x]` done · `[!]` blocked (why)

## Phase 0: Spikes
- [ ] MN-0.1 FluidAudio end-to-end on a file
- [ ] MN-0.2 macOS dual capture (process tap + mic)
- [ ] MN-0.3 Speaker-ID threshold calibration
- [ ] MN-0.4 Mic bleed handling
- [ ] MN-0.5 Summary provider comparison
- [ ] **Gate:** ARCHITECTURE/DECISIONS updated

## Phase 1: Headless pipeline
- [ ] MN-1.1 MinutesKit package + CI
- [ ] MN-1.2 Models + GRDB store
- [ ] MN-1.3 Speech services (FluidAudio wrappers)
- [ ] MN-1.4 Merger
- [ ] MN-1.5 Pipeline orchestrator
- [ ] MN-1.6 minutes-cli
- [ ] MN-1.7 Speaker ID (matcher + enrolment)
- [ ] MN-1.8 Calendar (EventKit, names)
- [ ] **M1** CLI auto-identifies speakers in a second file

## Phase 2: Mac capture + shell
- [ ] MN-2.1 XcodeGen project + entitlements
- [ ] MN-2.2 Chunked audio writer
- [ ] MN-2.3 Mic + system tap recorders
- [ ] MN-2.4 Menu bar, recorder panel, onboarding
- [ ] MN-2.5 Library + transcript view

## Phase 3: Review + people
- [ ] MN-3.1 Speaker review drag-assign UI
- [ ] MN-3.2 Segment reassign
- [ ] MN-3.3 Lock + enrol
- [ ] MN-3.4 People view
- [ ] MN-3.5 Meeting ↔ event linking

## Phase 4: Summaries + exports
- [ ] MN-4.1 Summarize core
- [ ] MN-4.2 Providers
- [ ] MN-4.3 Summary editor
- [ ] MN-4.4 Export protocol + Markdown
- [ ] MN-4.5 Parachute adapter
- [ ] MN-4.6 Finalize flow
- [ ] MN-4.7 Settings UI
- [ ] **M2 / Mac MVP** Real call → Parachute linked note

## Phase 5: Mac v1
- [ ] MN-5.1 Meeting detection + prompts
- [ ] MN-5.2 Live transcript
- [ ] MN-5.3 Google Docs adapter
- [ ] MN-5.4 Retention
- [ ] MN-5.5 Consent helpers
- [ ] MN-5.6 Release pipeline

## Phase 6: iOS
- [ ] MN-6.1 Recording + Live Activity
- [ ] MN-6.2 Event notifications
- [ ] MN-6.3 On-device pipeline
- [ ] MN-6.4 Compact review UI
- [ ] MN-6.5 iOS exports

## Log
- 2026-10-13: Planning docs created. Full research corpus completed and verified from primary sources:
  - FluidAudio SDK docs: Parakeet Ultra (LibriSpeech 2.13% clean) selected as default; `OfflineDiarizerConfig.Clustering` supports `minSpeakers`/`maxSpeakers`/`numSpeakers` hints from calendar; WeSpeaker 256-dim embeddings with `SpeakerManager`.
  - Meetily repo inspected (`CLAUDE.md`, Tauri 2.x, Rust `cpal`/`whisper-rs`, Next.js 14): confirmed diarization is PRO-only and no iOS support; building native Swift verified.
  - Platform APIs verified: Core Audio Process Taps (`AudioHardwareCreateProcessTap` + `CATapDescription` + `NSAudioCaptureUsageDescription`), iOS 18 `AudioRecordingIntent` for Lock Screen/Live Activity recording, Apple Foundation Models 4,096-token `@Generable` guided generation, EventKit `mailto:` participant emails.
  - Parachute vault verified from local `omni-app` source: paths `vault/meetings/<YYYY-MM-DD>/<slug>` and `vault/people/<slug>`, relationship `attended-by`, `if_exists: "ignore"` to avoid 409s.
  - Google Docs verified: Markdown -> HTML (`text/html`) -> Google Doc conversion.
