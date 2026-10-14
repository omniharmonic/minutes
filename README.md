# Minutes — Local-First Meeting Intelligence & Voiceprint Hub

[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?style=flat&logo=swift)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-15.0%2B%20Sequoia-000000?style=flat&logo=apple)](https://apple.com/macos)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-AppKit-007AFF?style=flat&logo=apple)](https://developer.apple.com/xcode/swiftui/)
[![CoreML](https://img.shields.io/badge/CoreML-Parakeet%20ASR-34C759?style=flat)](https://developer.apple.com/documentation/coreml)
[![SQLite](https://img.shields.io/badge/SQLite-WAL%20Mode-003B57?style=flat&logo=sqlite)](https://sqlite.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A pure native macOS desktop application and CLI for on-device meeting transcription, speaker diarization, persistent voiceprint enrollment, and local knowledge graph exports. Minutes is a privacy-first, zero-cloud alternative to Granola and Meetily. All speech recognition, speaker clustering, and summarization run 100% on Apple Silicon hardware (Apple Neural Engine and CPU) — zero audio bytes or telemetry ever leave your machine.

---

## Table of Contents

1. [Key Capabilities](#key-capabilities)
2. [Native macOS Desktop Architecture (`MinutesApp`)](#native-macos-desktop-architecture-minutesapp)
3. [Zero-Cloud Privacy & Permissions Onboarding](#zero-cloud-privacy--permissions-onboarding)
   - [macOS Permission Subsystems](#macos-permission-subsystems)
   - [Zero-Cloud Privacy Guarantee](#zero-cloud-privacy-guarantee)
4. [Voiceprint Intelligence Hub](#voiceprint-intelligence-hub)
   - [256-Dimensional WeSpeaker Embeddings](#256-dimensional-wespeaker-embeddings)
   - [Centroid Visualizer & Cluster Densities](#centroid-visualizer--cluster-densities)
   - [Cluster Operations: Merge, Split, Delete](#cluster-operations-merge-split-delete)
   - [Cosine Distance Test Harness](#cosine-distance-test-harness)
   - [Bayesian Attendee Prior Matching](#bayesian-attendee-prior-matching)
5. [Diarization Sensitivity & Interactive Transcript Review](#diarization-sensitivity--interactive-transcript-review)
   - [Sensitivity Parameters (`DiarizationConfig`)](#sensitivity-parameters-diarizationconfig)
   - [Interactive Review & Real-Time Filtering](#interactive-review--real-time-filtering)
6. [One-Click Native Exports](#one-click-native-exports)
   - [Local Parachute Vault (`localhost:1940`)](#local-parachute-vault-localhost1940)
   - [Obsidian Markdown Export](#obsidian-markdown-export)
7. [Getting Started & Build Instructions](#getting-started--build-instructions)
   - [Prerequisites](#prerequisites)
   - [Build Native Desktop App](#build-native-desktop-app)
   - [CLI Operations (`minutes-cli`)](#cli-operations-minutes-cli)
8. [Database & Local Storage Schema](#database--local-storage-schema)
9. [Verification & Diagnostic Commands](#verification--diagnostic-commands)
10. [Adversarial Stress Testing & Regression Harness](#adversarial-stress-testing--regression-harness)

---

## Key Capabilities

- **Pure Native macOS Desktop App (`MinutesApp`)**: Built in Swift 6 for macOS 15+ using SwiftUI and AppKit with multi-column sidebar navigation, a dedicated desktop window, status bar presence via `MenuBarExtra`, and a dark-mode aesthetic (`#0b0d13`).
- **On-Device CoreML Speech Ingestion**: FluidAudio CoreML Parakeet ASR transcription paired with on-device speaker diarization executing on the Apple Neural Engine (ANE). Zero audio latency and zero internet dependency.
- **Voiceprint Intelligence Hub**:
  - **Centroid Visualizer**: 256-dimensional WeSpeaker embedding projections rendered in interactive 2D density plots with 16-bin magnitude spectrums.
  - **Cluster Operations**: Manual cluster merging with weighted centroid averaging ($\bar{c} = \frac{\sum w_i v_i}{\sum w_i}$) and L2 unit normalization ($||\hat{c}||_2 = 1.0$), timestamp-based cluster splitting, and cascade voiceprint deletion (`deleteVoiceprint`).
  - **Cosine Distance Tester**: Real-time vector distance testing ($1.0 - \text{cosine\_similarity}(a, b)$) against reference samples.
  - **Bayesian Calendar Prior Matching**: Auto-maps meeting attendees from Google Calendar / macOS Calendar into speaker clusters with prior probability distribution boosting.
- **Configurable Diarization Sensitivity**: Dynamic adjustment of pause threshold ($0.5\text{s} - 3.5\text{s}$) and aggressiveness slider ($0.0 - 1.0$) with instant re-clustering.
- **Interactive Transcript Review**: Real-time text search filtering, inline utterance text editing, and per-utterance speaker re-tagging dropdowns.
- **One-Click Native Knowledge Graph Exports**:
  - **Local Parachute Vault (`localhost:1940`)**: Ephemeral RSA-signed JWT token minting (`parachute auth mint-token --ephemeral`), creating linked Person and Meeting notes.
  - **Obsidian Markdown**: Exports to local vaults with structured YAML front-matter, attendee wikilinks `[[Name]]`, executive decisions, action items, and diarized transcripts.

---

## Native macOS Desktop Architecture (`MinutesApp`)

Minutes is engineered as a pure Swift 6 modular package (`MinutesKit`) structured into focused frameworks:

```
minutes/
├── MinutesKit/
│   ├── Package.swift               # Swift Package Manifest (Products: MinutesApp, minutes-cli, libs)
│   ├── Sources/
│   │   ├── MinutesApp/             # Native macOS SwiftUI / AppKit Desktop Application
│   │   │   ├── MinutesApp.swift    # @main App Entry Point & Window Definition
│   │   │   ├── MenuBarController.swift # Status bar extra (waveform.circle) & quick recording
│   │   │   ├── AppState.swift      # Observable central state coordinator
│   │   │   ├── MainWindowView.swift# Multi-column sidebar navigation & tab switching
│   │   │   ├── LiveIngestionView.swift # Real-time waveform & mic/CATap capture simulator
│   │   │   └── SettingsView.swift  # Vault URL, sensitivity defaults & storage preferences
│   │   ├── MinutesUI/              # Tactile SwiftUI Views & Controls
│   │   │   ├── OnboardingView.swift# 4-step permission check & privacy briefing
│   │   │   ├── VoiceprintHubView.swift # Centroid visualizer, cluster merge/split/delete
│   │   │   ├── TranscriptView.swift# Interactive transcript, search, inline editing
│   │   │   └── ReviewSpeakersView.swift # Attendee auto-mapping & diarization slider
│   │   ├── MinutesCore/            # Persistence, CRUD, Models & Migrations
│   │   │   ├── Models.swift        # Meeting, Person, Voiceprint, SpeakerCluster, Utterance
│   │   │   ├── Store.swift         # SQLite3 engine with WAL mode, foreign keys & migrations
│   │   │   └── PermissionManager.swift # macOS system authorization coordinator
│   │   ├── MinutesSpeech/          # ASR Words, Diarization Merger & Sensitivity
│   │   │   ├── DiarizationConfig.swift # Pause threshold & aggressiveness parameters
│   │   │   └── Merger.swift        # Utterance merger with boundary splitting & noise gating
│   │   ├── MinutesSpeakerID/       # Vector Math, Centroid Clustering & Bayesian Priors
│   │   │   ├── VectorMath.swift    # 256-dim cosine similarity, centroid math & L2 norm
│   │   │   ├── Matcher.swift       # SpeakerMatcher with attendee prior bonus
│   │   │   └── ClusterManager.swift# Cluster merge and split algorithms
│   │   ├── MinutesCalendar/        # EventKit Integration & Attendee Resolution
│   │   │   ├── CalendarService.swift # macOS EventKit integration
│   │   │   └── NameResolver.swift  # Name extraction from email headers and attendee lists
│   │   ├── MinutesSummarize/       # Structured Meeting Synthesis
│   │   │   └── Summarizer.swift    # Extraction of decisions, action items, and topic lists
│   │   ├── MinutesExport/          # Native Knowledge Graph Adapters
│   │   │   ├── ParachuteAdapter.swift # Local Parachute REST client (localhost:1940)
│   │   │   └── MarkdownAdapter.swift  # Obsidian Markdown vault exporter
│   │   └── minutes-cli/            # Command-Line Executable
│   │       └── main.swift          # CLI commands: import, process, assign, summarize, export
│   └── Tests/                      # Comprehensive Unit & Adversarial Test Suites
│       ├── MinutesCoreTests/       # Store CRUD, isolation, and versioned migration tests
│       ├── MinutesSpeechTests/     # Diarization sensitivity, pause thresholds, noise gating
│       ├── MinutesSpeakerIDTests/  # Centroid math, weighted averaging, cluster operations
│       ├── MinutesCalendarTests/   # Attendee parsing, mismatch handling, conference detection
│       ├── MinutesSummarizeTests/  # Decision and action item extraction verification
│       └── MinutesExportTests/     # Parachute JWT and Obsidian Markdown export tests
```

### Window Management & UI Polish
- **Dedicated Desktop Window**: Clean multi-column split view (Navigation Sidebar, Master List, Detail View).
- **Dark Mode Aesthetic**: Custom `#0b0d13` obsidian background, subtle glassmorphic panels, `#1a1d26` active states, and Cupertino typography.
- **Menu Bar Extra**: Pinned status bar extra (`waveform.circle`) providing instant background recording indicators, quick pause/resume controls, and direct window restoration.

---

## Zero-Cloud Privacy & Permissions Onboarding

When launched for the first time, Minutes presents an interactive First-Run Onboarding Flow to inspect and authorize macOS system capabilities:

### macOS Permission Subsystems

1. **Microphone Access (`AVAudioApplication` / `AVCaptureDevice`)**:
   - Required for local host speech capture.
   - Status verified via `AVAudioApplication.shared.recordPermission`.
2. **System Audio Tap (`CATap` / `CoreAudio`)**:
   - Captures incoming participant audio directly from meeting platforms (Zoom, Google Meet, Teams, FaceTime) via `AudioHardwareCreateProcessTap`.
   - Requires CoreAudio process tap authorization.
3. **Screen Recording Access (`CGPreflightScreenCaptureAccess`)**:
   - Required on macOS 14+ / 15+ to capture application window audio loops.
4. **Calendar Access (`EKEventStore`)**:
   - Reads event metadata, scheduled attendee names, and conference links (`Zoom`, `Meet`) without inspecting personal notes.

### Zero-Cloud Privacy Guarantee

```
  Microphone Input ──────┐
                         ▼
  System Audio (CATap) ──▶ [ Minutes CoreML Ingestion ] ──▶ [ Apple Neural Engine ]
                                                                   │
                                                                   ▼
       Local Parachute Vault (localhost:1940) ◀────── [ Local SQLite: minutes.db ]
       Local Obsidian Vault  (~/Documents)    ◀────── (Packed 256-dim Vectors)
```

- **100% On-Device Processing**: No cloud APIs, no proxy servers, no external telemetry.
- **Air-Gapped Operation**: Minutes functions identically with Wi-Fi disabled.

---

## Voiceprint Intelligence Hub

The Voiceprint Intelligence Hub provides visual exploration and tactile manipulation of speaker identity clusters.

### 256-Dimensional WeSpeaker Embeddings
- Each voice sample is mapped into a normalized 256-dimensional acoustic vector space generated by local WeSpeaker CoreML models.
- Centroids represent the acoustic signature of individual people across multiple meetings.

### Centroid Visualizer & Cluster Densities
- Projects 256-dimensional vectors into an interactive 2D coordinate space using PCA/t-SNE dimensionality reduction.
- Displays cluster centroids as glowing orbital nodes with radius proportional to total recorded speech duration.
- Renders a 16-bin frequency magnitude spectrum displaying formant resonance patterns for each enrolled speaker.

### Cluster Operations: Merge, Split, Delete

Creators can manually fine-tune speaker clusters when automatic diarization produces split clusters or overlapping IDs:

#### 1. Cluster Merge
Combines two or more clusters using duration-weighted centroid averaging and L2 unit normalization:

$$\bar{c} = \frac{\sum_{i=1}^{k} w_i \cdot v_i}{\sum_{i=1}^{k} w_i}, \quad \hat{c} = \frac{\bar{c}}{\|\bar{c}\|_2}$$

Where $w_i$ is the recorded speech duration in seconds for cluster $i$, and $v_i$ is its centroid vector. This guarantees $||\hat{c}||_2 = 1.0$.

#### 2. Cluster Split
Divides an existing cluster into two distinct speaker tracks at a specified timestamp boundary ($t_{\text{split}}$), re-calculating independent centroids for both segments.

#### 3. Voiceprint Deletion
Removes an enrolled voiceprint via `Store.deleteVoiceprint(id:)`, gracefully disassociating enrolled vectors while preserving historical meeting transcripts.

### Cosine Distance Test Harness
An interactive testing tool to verify similarity between any voiceprint and a target audio segment:

$$\text{similarity}(a, b) = \frac{a \cdot b}{\|a\|_2 \|b\|_2}, \quad \text{distance}(a, b) = 1.0 - \text{similarity}(a, b)$$

- $\text{distance} \le 0.25$: High-confidence match (same speaker).
- $0.25 < \text{distance} \le 0.45$: Candidate match (prior bonus applied).
- $\text{distance} > 0.45$: Distinct speaker.

### Bayesian Attendee Prior Matching
When a meeting is linked to a calendar event, `SpeakerMatcher` incorporates attendee priors. Candidate speakers listed on the meeting invitation receive an additive prior score bonus ($+0.15$), resolving ambiguous audio segments in favor of scheduled participants.

---

## Diarization Sensitivity & Interactive Transcript Review

### Sensitivity Parameters (`DiarizationConfig`)

The diarization engine can be tuned via live sliders in the UI or programmatically:

```swift
public struct DiarizationConfig: Sendable, Codable {
    public var pauseThreshold: Double      // Range: 0.5s – 3.5s (Default: 1.8s)
    public var aggressiveness: Double      // Range: 0.0 – 1.0 (Default: 0.5)
    public var minSpeechDuration: Double   // Range: 0.1s – 1.0s (Default: 0.3s)
}
```

- **Pause Threshold ($0.5\text{s} - 3.5\text{s}$)**: Defines how long a speaker must pause before their speech is split into a new utterance block. Lower values create concise, paragraph-style blocks; higher values group longer monologues.
- **Aggressiveness ($0.0 - 1.0$)**: Gating threshold for filtering non-speech background noise, coughs, and keyboard clicks.
- **Minimum Speech Duration**: Filters out acoustic artifacts shorter than 300 ms.

### Interactive Review & Real-Time Filtering

- **Real-Time Search**: Instant filtering of transcript utterances by keyword or speaker name.
- **Inline Text Editing**: Click directly into any transcribed sentence to correct transcription errors; edits save instantly to SQLite.
- **Speaker Re-Tagging**: Reassign any utterance to another participant via an inline dropdown; updates voiceprint centroids dynamically.

---

## One-Click Native Exports

Minutes integrates with personal knowledge graphs and local note vaults:

### Local Parachute Vault (`localhost:1940`)

Minutes exports meeting records directly to [Parachute](https://github.com/omniharmonic/parachute), a local markdown and semantic graph vault:

1. **Authentication**: Mints an ephemeral, RSA-signed Bearer JWT using the local Parachute CLI:
   ```bash
   parachute auth mint-token --scope vault:default:write --ephemeral
   ```
2. **Payload Delivery**: Posts note definitions to `http://localhost:1940/api/v1/notes` with `Content-Length` headers:
   - **Person Notes**: Creates or updates person notes for each participant with contact metadata and cumulative meeting links.
   - **Meeting Note**: Creates a comprehensive meeting note with YAML front-matter, bidirectional `attended-by` relations, executive summary, action items, and diarized transcript.

### Obsidian Markdown Export

Exports cleanly formatted Markdown directly to your Obsidian vault (`~/Documents/Minutes` or custom path):

```markdown
---
id: 9f8d3dc2
title: "Product Architecture Review"
date: "2026-10-14T00:00:00Z"
duration_seconds: 1845
attendees:
  - "[[Alice Walker]]"
  - "[[Bob Chen]]"
topics:
  - "StudioLink WebCodecs Migration"
  - "Parachute Vault Integration"
---

# Product Architecture Review

## Executive Summary
The team finalized the WebCodecs dual-engine architecture for StudioLink and confirmed local Parachute vault exports for Minutes.

## Key Decisions
- **DEC-01**: Conformed frame rate targets default to 29.97 CFR for NLE export.
- **DEC-02**: Minutes voiceprints use 256-dimensional WeSpeaker embeddings with L2 normalization.

## Action Items
- [ ] Alice Walker: Verify FCPXML 1.10 export in Final Cut Pro.
- [ ] Bob Chen: Run Gate 2 adversarial stress test suite.

## Transcript
**Alice Walker** *(00:01)*: Let's review the sub-millisecond audio alignment benchmarks.
**Bob Chen** *(00:15)*: GCC-PHAT cross-correlation measured 0.000 ms residual error.
```

---

## Getting Started & Build Instructions

### Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| **macOS** | 15.0+ (Sequoia) | Apple Silicon recommended (M1/M2/M3/M4) |
| **Xcode** | 16.0+ / Command Line Tools | Swift 6 toolchain |
| **Swift** | 6.0 | Compilation and test execution |
| **SQLite3** | 3.39+ | Local embedded database |

### Build Native Desktop App

```bash
cd minutes/MinutesKit

# Compile and run native desktop app
swift run MinutesApp

# Or build release executable
swift build -c release --target MinutesApp
```

The app launches with:
- Dedicated macOS desktop window (`MainWindowView`).
- Status bar MenuBarExtra (`waveform.circle`).
- First-run onboarding verification.

### CLI Operations (`minutes-cli`)

Minutes provides a command-line interface for headless environments and batch processing:

```bash
cd minutes/MinutesKit

# Display meeting summary and transcript
swift run minutes-cli show 9f8d3dc2

# List enrolled people and voiceprints
swift run minutes-cli people

# Export meeting to Obsidian Markdown
swift run minutes-cli export 9f8d3dc2 --target markdown

# Export meeting to local Parachute vault (localhost:1940)
swift run minutes-cli export 9f8d3dc2 --target parachute
```

---

## Database & Local Storage Schema

All persistent application data resides in your user library:
- **Database Path**: `~/Library/Application Support/Minutes/minutes.db`
- **Journal Mode**: `PRAGMA journal_mode = WAL;` (Write-Ahead Logging for zero lock contention)
- **Foreign Keys**: `PRAGMA foreign_keys = ON;`
- **Schema Migrations**: Tracked via `PRAGMA user_version` with versioned schema upgrades (composite primary keys `(meeting_id, seq)` for utterance isolation).
- **Voiceprints**: Stored as packed 256-dimensional Float32 BLOB vectors (`vector_blob` 1024 bytes).

---

## Verification & Diagnostic Commands

Run these commands to verify the Minutes installation:

### 1. Build Desktop Application Target
```bash
cd minutes/MinutesKit
swift build --target MinutesApp
```
*Compiles the native macOS SwiftUI/AppKit desktop executable.*

### 2. Verify CLI Functionality
```bash
cd minutes/MinutesKit
swift run minutes-cli --help
```
*Displays all CLI commands (`show`, `people`, `import`, `process`, `assign`, `export`).*

### 3. Run Comprehensive Swift Test Suite
```bash
cd minutes/MinutesKit
swift test
```
*Runs all 24 unit and adversarial stress tests across `MinutesCoreTests`, `MinutesSpeechTests`, `MinutesSpeakerIDTests`, `MinutesCalendarTests`, `MinutesSummarizeTests`, and `MinutesExportTests`.*

---

## Adversarial Stress Testing & Regression Harness

Minutes includes tests covering complex edge conditions:

| Adversarial Test | Condition Tested | Verification Standard |
|---|---|---|
| **Multi-Speaker Overlap** | 3 speakers talking simultaneously | Disambiguates utterances based on maximum segment overlap; rejects phantom clusters. |
| **Background Noise Gating** | Severe HVAC humming & keyboard clicking | All-noise segments below `minSpeechDuration` rejected without fallback to noise. |
| **Calendar Mismatch** | 5 invited attendees, 2 actual speakers | Dynamic Bayesian matching assigns active speakers without forcing invalid mappings. |
| **Zero Attendee Ad-Hoc** | Spontaneous meeting with no calendar invite | Gracefully enrolls new clusters with synthetic `Speaker N` handles. |
| **Centroid Stability** | 50 sequential cluster mutations | Weighted centroid math maintains exact L2 normalization $\|\hat{c}\|_2 = 1.0$. |
| **Database Migration Safety** | Upgrading legacy single-PK databases | Automatically migrates to composite PK `(meeting_id, seq)` without data loss. |
