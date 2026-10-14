# Minutes: Status & Milestone Roadmap

Status Definitions:
- `[x] G0-VERIFIED`: Remediated, verified with adversarial tests, and isolated from production/personal storage.
- `[~] IN PROGRESS`: Active implementation gate.
- `[ ] PLANNED`: Contract defined; implementation / device validation pending.
- `[!] BLOCKED`: External dependency or hardware blocker.

---

## Milestone Gates (Audit 2026-10-14 Framework)

### Gate G0: Truth, Safety & Test Isolation
- [x] **G0.1 Fabricated Extractive Fallback Removed**: Deleted fabricated decision and action-item strings in `Summarizer.swift`. Fallback is now strictly factual.
- [x] **G0.2 Acoustic Similarity Floor & Clamping**: `Matcher.swift` enforces minimum acoustic similarity floor (`maxSim >= 0.40`) before calendar bonus and clamps `effectiveScore` to `[0.0, 1.0]`.
- [x] **G0.3 SQLite Meeting Isolation**: `Store.swift` upsert preserves meeting/track boundaries (`ON CONFLICT DO UPDATE SET meeting_id, track_id`).
- [x] **G0.4 Scoped Attendees**: `Store.swift` and `AppState.swift` scope attendees per meeting via `listPeopleForMeeting(meetingId:)` rather than returning all database records.
- [x] **G0.5 Fake UTTERANCES & Synthetic Vectors Removed**: `stopAndProcessMeeting()` no longer injects random 256-dim vectors or canned text. Demo preview is isolated to `loadDemoMeetingFixture()`.
- [x] **G0.6 Audio Validation in CLI and App**: `minutes-cli` and `LiveIngestionView.swift` validate non-empty audio files and report errors instead of attempting UTF-8 string decoding fallback.
- [x] **G0.7 Isolated Test Storage**: `MinutesClient` and `conftest.py` use disposable temporary database directories (`--data-dir`), never touching personal `~/Library/Application Support/Minutes`.
- **Exit Evidence**: All 32 Swift unit tests pass cleanly; invalid audio inputs fail truthfully; root test suite isolated. **STATUS: G0 COMPLETE.**

---

### Gate M1: Real Speech, Diarization & Pipeline Feasibility
- [~] **M1.1 Speech Pipeline Integration**: Wire native CoreML / FluidAudio ASR with genuine audio files (`.wav` / `.m4a`).
- [ ] **M1.2 Diarization Calibration**: Derive speaker segments from real multi-speaker audio with honest DER/WER reporting.
- [ ] **M1.3 Resumable Processing**: State machine transitions (`importing` → `transcribing` → `diarizing` → `review` → `exported`).
- [ ] **M1.4 CLI End-to-End Pipeline**: `minutes-cli process` executing genuine local model inference without text injection.

---

### Gate M2: Trustworthy Capture & Confirmed Learning
- [ ] **MN-2.1 macOS Process Tap & Mic Separation**: Dual-channel recording without mic bleed.
- [ ] **MN-2.2 Calendar Context Integration**: Optional EventKit / Google Calendar attendee hints as contextual priors only.
- [ ] **MN-2.3 Confirmed Speaker Enrollment**: User opt-in to save confirmed centroids into persistent voiceprint library.
- [ ] **MN-2.4 Grounded Summarization**: LLM / extractive summarization strictly with source timestamps and citations.

---

### Gate I1 & M3: Mobile & Cloud Integration
- [ ] **I1.1 Restricted Prism Ingestion**: Dedicated client credentials, scoped token permissions, outbox retry.
- [ ] **M3.1 iOS Native Target**: Background mic recording, locked-screen support, physical iPhone TestFlight build.

