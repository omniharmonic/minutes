# Minutes: Local-First Meeting Intelligence & Voiceprints

A pure native macOS desktop application and CLI for on-device meeting transcription, speaker diarization, persistent voiceprint enrollment, and local knowledge graph exports. A privacy-first, zero-cloud alternative to Granola and Meetily.

---

## Key Capabilities

- **Pure Native macOS Desktop App (`MinutesApp`)**: Built in Swift 6 for macOS 15+ using SwiftUI and AppKit with `MenuBarExtra` presence, dark-mode `#0b0d13` aesthetic, multi-column navigation, and window management.
- **On-Device Speech Processing**: Powered by FluidAudio CoreML Parakeet transcription and local speaker diarization executing on the Apple Neural Engine (ANE). Zero audio leaves your Mac.
- **Speaker Review & Voiceprint Hub**:
  - Calendar attendee auto-mapping with interactive selector and drag-and-drop assignment.
  - Centroid visualization displaying 256-dimensional WeSpeaker embeddings and 16-bin magnitude spectrums.
  - Manual cluster fine-tuning: merge clusters (weighted centroid averaging $\bar{c} = \frac{\sum w_i v_i}{\sum w_i}$ and L2 normalization $\hat{c} = \frac{\bar{c}}{\|\bar{c}\|}$), split clusters by timestamp boundary, and delete voiceprints.
  - Cosine distance and similarity test harness (`VectorMath.cosineSimilarity`, `VectorMath.cosineDistance`).
- **Configurable Diarization Sensitivity**: Dynamic adjustment of pause threshold (0.5s–3.5s) and aggressiveness (0.0–1.0) sliders.
- **Interactive Transcript Review**: Real-time search query filtering, inline utterance text editing, and per-utterance speaker re-tagging.
- **One-Click Native Exports**:
  - **Parachute Vault**: Direct local push to `http://localhost:1940/api/v1/notes` using ephemeral JWT token minting (`parachute auth mint-token`) and bidirectional `attended-by` relationships.
  - **Obsidian Markdown**: Exports to `~/Documents/Minutes` (or custom directory) with YAML front-matter, attendees, decisions, action items, topics, and full speaker transcript.
- **First-Run Permissions & Privacy Onboarding**: Live permission status checks and interactive authorization for Microphone (`AVCaptureDevice`), System Audio (`CATap`), Screen Recording (`CGPreflightScreenCaptureAccess`), and Calendar (`EKEventStore`).

---

## Architecture Overview

```
minutes/
├── MinutesKit/
│   ├── Package.swift               # Swift Package manifest (Products: MinutesApp, minutes-cli, libraries)
│   ├── Sources/
│   │   ├── MinutesApp/             # Native macOS SwiftUI desktop application & MenuBarExtra
│   │   │   ├── MinutesApp.swift    # @main App entry point
│   │   │   ├── AppState.swift      # Central state & data coordinator
│   │   │   ├── MainWindowView.swift# Multi-column desktop window & tab navigation
│   │   │   ├── LiveIngestionView.swift # Ingestion simulator & file importer
│   │   │   └── SettingsView.swift  # Vault endpoint and preference configuration
│   │   ├── MinutesCore/            # SQLite store, packed vector blobs, migrations, permission manager
│   │   │   ├── Models.swift        # Meeting, Person, Voiceprint, SpeakerCluster, Utterance
│   │   │   ├── Store.swift         # Thread-safe SQLite3 engine with WAL mode and migration safety
│   │   │   └── PermissionManager.swift # macOS system permission coordinator
│   │   ├── MinutesSpeech/          # ASR words, diarization merger, sensitivity parameters
│   │   │   └── Merger.swift        # TranscriptMerger with configurable DiarizationConfig
│   │   ├── MinutesSpeakerID/       # Vector math, speaker matching, cluster operations
│   │   │   ├── Matcher.swift       # VectorMath (cosine, centroids, L2 norm) and SpeakerMatcher
│   │   │   └── ClusterManager.swift# Cluster merge and split algorithms
│   │   ├── MinutesCalendar/        # Name resolution and conference URL detection
│   │   ├── MinutesSummarize/       # Structured meeting summarization (decisions, actions, topics)
│   │   ├── MinutesExport/          # Parachute vault (localhost:1940) & Obsidian Markdown adapters
│   │   ├── MinutesUI/              # SwiftUI views (VoiceprintHub, ReviewSpeakers, Transcript, Onboarding)
│   │   └── minutes-cli/            # Command-line interface executable
│   └── Tests/
│       ├── MinutesCoreTests/       # CRUD and versioned SQLite migration tests
│       ├── MinutesSpeechTests/     # Overlapping speech, noise gating, sensitivity tests
│       ├── MinutesSpeakerIDTests/  # Centroid math, weighted averaging, cluster merge/split tests
│       ├── MinutesCalendarTests/   # Calendar mismatch and edge-case name resolver tests
│       ├── MinutesSummarizeTests/  # Structured summary extraction tests
│       └── MinutesExportTests/     # Obsidian and Parachute export tests
└── docs/                           # Architecture specifications, PRD, and research findings
```

---

## Quickstart & Launch

### 1. Launch Native Desktop App
```bash
cd minutes/MinutesKit
swift run MinutesApp
```
This builds and launches the dedicated macOS desktop window with full sidebar navigation, live recorder, Voiceprint Hub, and menu bar extra (`waveform.circle`).

### 2. Run Comprehensive Test Suite
```bash
cd minutes/MinutesKit
swift test
```
Executes all 24 programmatic and adversarial stress tests across all 6 modules.

### 3. Use CLI Interface
```bash
cd minutes/MinutesKit
swift run minutes-cli show 9f8d3dc2
swift run minutes-cli people
swift run minutes-cli export 9f8d3dc2 --target markdown
swift run minutes-cli export 9f8d3dc2 --target parachute
```

---

## Database & Local Data Storage

All data is stored in standard SQLite on your local filesystem:
- Path: `~/Library/Application Support/Minutes/minutes.db`
- Features: WAL mode enabled, foreign key cascades, versioned schema migrations (`PRAGMA user_version`), packed 256-dimensional Float32 BLOB vectors for WeSpeaker centroids.
