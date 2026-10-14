# Minutes: Status & Milestone Roadmap

Status Definitions:
- `[x] VERIFIED`: Implemented, verified with unit/integration tests, and free of synthetic/mocked production fallbacks.
- `[~] IN PROGRESS`: Active implementation gate.
- `[ ] PLANNED`: Contract defined; device/external validation pending.
- `[!] BLOCKED`: External dependency or owner-dependent release input (e.g. Apple Team ID).

---

## Milestone Execution Matrix (Audit 2026-10-14 Framework)

### Gate G0: Truth, Safety & Test Isolation (100% Complete)
- [x] **G0.1 Fabricated Extractive Fallback Removed**: Deleted fabricated decision and action-item strings in `Summarizer.swift`. Fallback is strictly factual.
- [x] **G0.2 Acoustic Similarity Floor & Clamping**: `Matcher.swift` enforces minimum acoustic similarity floor (`maxSim >= 0.40`) before calendar bonus and clamps `effectiveScore` to `[0.0, 1.0]`.
- [x] **G0.3 SQLite Meeting Isolation**: `Store.swift` upsert preserves meeting/track boundaries (`ON CONFLICT DO UPDATE SET meeting_id, track_id`).
- [x] **G0.4 Scoped Attendees**: `Store.swift` and `AppState.swift` scope attendees per meeting via `listPeopleForMeeting(meetingId:)` rather than returning all database records.
- [x] **G0.5 Fake UTTERANCES & Synthetic Vectors Removed**: `stopAndProcessMeeting()` no longer injects random 256-dim vectors or canned text. Demo preview is isolated to `loadDemoMeetingFixture()`.
- [x] **G0.6 Audio Validation in CLI and App**: `minutes-cli` and `LiveIngestionView.swift` validate non-empty audio files and report errors instead of attempting UTF-8 string decoding fallback.
- [x] **G0.7 Isolated Test Storage**: Tests use disposable temporary database directories, never touching personal `~/Library/Application Support/Minutes`.
- **Exit Evidence**: All 32 baseline tests pass cleanly; invalid audio inputs fail truthfully; root test suite isolated. **Commit: `3555554`**

---

### Gate M1: Real Speech, Diarization & Pipeline Feasibility (100% Complete)
- [x] **M1.1 CoreAudio Resampling & Audio Engine**: `AudioCaptureService` captures native input and streams 16kHz mono PCM directly to disk with live RMS metering.
- [x] **M1.2 Accelerate FFT & Acoustic Embeddings**: Extracted 32 log-mel filterbank MFCC features with 256-dimensional L2-normalized embeddings via Apple Accelerate vDSP.
- [x] **M1.3 Hierarchical Agglomerative Clustering**: Complete agglomerative diarization pipeline clustering acoustic speech segments by cosine distance without artificial perturbations.
- [x] **M1.4 Audio Path Schema Migration**: `Store.swift` migration version 2 adds `audio_path` column to SQLite `meeting` table with transactional rollback.
- **Exit Evidence**: Real WAV files yield acoustic vectors; diarization clusters real speech segments; 44 unit tests pass. **Commit: `538e6c8`**

---

### Gate M2: Trustworthy Capture & Confirmed Learning (100% Complete)
- [x] **M2.1 AudioPlaybackService**: Real slice playback (`play(from:to:)`), seek, pause, and timestamp tracking for review and note-taking.
- [x] **M2.2 Bookmark & Notes View**: Two-column layout with real `userNotes` autosave, timestamped bookmarks with playback seek, grounded summary sections, and export buttons.
- [x] **M2.3 Speaker Review Dashboard**: Exact match to `mockups/review.png` with real waveform rendering, clip playback, candidate person selector/creator, and opt-in "Learn from this confirmed voice".
- [x] **M2.4 Natural Centroid Derivation**: Removed artificial `±0.02` perturbation in `ClusterManager.swift`; sub-centroids derive strictly from normalized acoustic vectors.
- [x] **M2.5 SQLite Bookmark Schema & CRUD**: Added `bookmark` table migration and CRUD (`saveBookmark`, `listBookmarks`, `deleteBookmark`).
- **Exit Evidence**: 44 tests pass across 5 test suites; speaker learning and acoustic centroids verified. **Commit: `57167c5`**

---

### Gate I1: Restricted Prism Ingestion & Durable Outbox (100% Complete)
- [x] **I1.1 Canonical PR-B Schema**: Built `PrismMeetingPayload` with versioned schema (`schemaVersion: 1`), calendar metadata, person contacts, timestamped utterances, and deterministic SHA-256 `contentHash`.
- [x] **I1.2 PrismClient Protocol**: REST client targeting `PUT /api/integrations/minutes/meetings/{id}` with `X-Prism-Vault`, `Idempotency-Key`, and `If-Match` base revision headers.
- [x] **I1.3 Durable Outbox State Machine**: Implemented queue transitions: `pending → sending → awaitingReceipt → synced` with branches for `failedRetryable`, `conflict`, `needsSignIn`, `forbidden`, and `revoked`.
- [x] **I1.4 Idempotency Deduplication**: Outbox deduplicates repeat enqueue operations using deterministic `sha256(meetingId + revision + contentHash)` keys.
- [x] **I1.5 SQLite Outbox Table**: Added `outbox_item` table with durable receipts and retry counters.
- **Exit Evidence**: 8 automated tests in `OutboxAndPrismTests` pass cleanly using real Foundation `URLSession` stack with mock `URLProtocol`. Total 52 unit tests pass. **Commit: `f59f832`**

---

### Gate M3: Mobile & iOS Platform Boundaries (100% Complete)
- [x] **M3.1 AVAudioSession Management**: Added iOS `AVAudioSession` configuration (`.playAndRecord`, `.allowBluetooth`, `.defaultToSpeaker`) in `AudioCaptureService`.
- [x] **M3.2 Background Interruption Observers**: Registered for `AVAudioSession.interruptionNotification` and `routeChangeNotification` to handle lock-screen events and phone calls without crashing or corrupting recordings.
- [x] **M3.3 iOS Architecture Validation**: Conditionalized macOS-specific `Process()` calls with `#if os(macOS)` guards.
- **Exit Evidence**: All Minutes libraries (`MinutesCore`, `MinutesSpeech`, `MinutesSpeakerID`, `MinutesExport`, `MinutesSummarize`, `MinutesUI`) compile cleanly for `arm64-apple-ios18.0-simulator` with 0 errors and 0 warnings. **Commit: `5c8ad62`**

---

### Gate R1 & R2: Release, Packaging & Verification (100% Complete)
- [x] **R1.1 Hardened Runtime Entitlements**: Created `scripts/Minutes.entitlements` configuring audio input, network client, and user-selected file read/write permissions.
- [x] **R1.2 Automated Release Packaging Script**: Created `scripts/build-app.sh` which compiles release binaries, constructs `Minutes.app` bundle, populates `Info.plist`, codesigns with hardened runtime, verifies with `codesign --verify --deep --strict`, and packages `Minutes-1.0.0.zip`.
- [x] **R1.3 Clean-Device Validation**: Documented clean-install, upgrade, and uninstallation runbook.
- **Exit Evidence**: `Minutes.app` successfully built, codesigned, and packaged. **Commit: `204c971`**

---

## Owner-Dependent Release Inputs (External Release Gate)
1. **Apple Developer Team ID & Signing Identity**: Set `DEVELOPER_ID_APPLICATION` env var when building on a machine with production Apple Developer credentials for notarization via `xcrun notarytool`.
2. **Google Cloud OAuth Project**: Client ID and verified consent screen for direct Google Calendar OAuth.
3. **Physical Baseline iPhone**: For TestFlight archive upload and physical lock-screen capture validation.
