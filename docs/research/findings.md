# Minutes: Verified Research Findings

> Comprehensive, primary-source verified technical and product research for the Minutes local-first meeting assistant.
> Sources inspected directly: FluidAudio Swift SDK repository & docs, Meetily Tauri repository & CLAUDE.md, omni-app Parachute vault integration (`apps/server/src/worker/*`), Apple Developer documentation, Google API documentation, and community user feedback.

---

## 1. Speech & Diarization Engine: FluidAudio

**Repository:** `github.com/FluidInference/FluidAudio` (Apache-2.0, Swift 6.0+, macOS 14+, iOS 17+)
**HuggingFace Models:** `huggingface.co/FluidInference`

### 1.1 ASR Models & Recommendations
FluidAudio optimizes all models for the Apple Neural Engine (ANE) with low memory footprint and zero GPU/MPS contention.

| Model Variant | Params & Format | Languages | Benchmarks / RTFx | Suitability & Recommendation |
|---|---|---|---|---|
| **Parakeet Ultra** (`AsrModelVersion.ultra`) | 0.6B params, INT8 encoder (595 MB) | 25 European + Japanese | LibriSpeech clean 2.13% (vs 2.27% v3), FLEURS 11.67% (vs 14.81% v3) | **Recommended Default.** Superior accuracy to v3 on every benchmark at identical speed. ANE on iOS 17+, macOS 15+. |
| **Parakeet TDT v3** (`AsrModelVersion.v3`) | 0.6B params, INT8 encoder | 25 European + Japanese | LibriSpeech clean 2.27%, 150× RTFx on ANE | Proven stable fallback. |
| **Parakeet Redux** (`AsrModelVersion.redux`) | 0.6B params, 2-bit ternary encoder (183 MB) | Multilingual | FLEURS 13.06% | Best for size-constrained iOS deployments. |
| **Parakeet EOU** | 120M params | English only | Streaming with End-of-Utterance | **Recommended for Live Preview** during recording. Latency < 200 ms. |
| **SenseVoiceSmall** | Non-autoregressive | 50+ languages | Broad multilingual fallback | Fast non-autoregressive alternative. |

### 1.2 Long-Form Audio Transcription Pipeline
* `SlidingWindowAsrManager`: Handles files of arbitrary duration by chunking on the fixed CoreML encoder window of **240,000 samples (15.0 seconds at 16 kHz)**.
* **Seam Geometry:**
  - Visible chunk: ≈ 14.96 s (frame-aligned to 80 ms encoder frames).
  - Overlap: 2.0 s target, minimum seam overlap 480 ms (6 frames).
  - Mel-context prepend (80 ms) or acoustic warmup prefix prevents boundary distortion.
  - Word/token timestamps: Emitted via `ASRResult.tokenTimings: [TokenTiming]`.
* **API Usage:**
  ```swift
  import FluidAudio

  let models = try await AsrModels.downloadAndLoad(version: .ultra)
  let asr = AsrManager(config: .default)
  try await asr.configure(models: models)

  // Direct file URL transcription with automatic 16kHz mono normalization:
  let result = try await asr.transcribe(audioFileURL, source: .system)
  print("Transcript: \(result.text), tokens: \(result.tokenTimings?.count ?? 0)")
  ```

### 1.3 Offline Diarization: `OfflineDiarizerManager`
* **Architecture:** Powerset segmentation (`pyannote_segmentation.mlmodelc`) + WeSpeaker embedding extraction (`wespeaker_v2.mlmodelc`) + PLDA/VBx agglomerative hierarchical clustering.
* **Platform Bug Note:** macOS 14 has a known BNNS crash (`EXC_BAD_ACCESS` in `libBNNS` / `BNNSGraphContextExecute_v2`). Apple resolved this in macOS 15. **Target platform must be macOS 15+ and iOS 18+**.
* **Speaker Count Constraints (Crucial Finding):**
  Unlike early assumptions, `OfflineDiarizerConfig.Clustering` **explicitly supports speaker hints**:
  ```swift
  public struct Clustering: Sendable {
      public var threshold: Double                   // Euclidean distance in [0, 2]
      public var minSpeakers: Int?                  // Minimum speakers
      public var maxSpeakers: Int?                  // Maximum speakers
      public var numSpeakers: Int?                  // Exact speaker count
      public var constrainedAssignment: Bool        // Forces K-Means reclustering
  }
  ```
  **Integration Value:** Minutes can pass the expected attendee count from Google Calendar directly into `minSpeakers` / `maxSpeakers` / `numSpeakers`!
* **Compute Optimization:** `skipStrategy: .maskSimilarity` skips redundant embedding extractions when speech masks are identical to cached ones, saving ~6.5 ms per window on ANE.
* **Batch Diarization API:**
  ```swift
  let config = OfflineDiarizerConfig()
  let diarizer = OfflineDiarizerManager(config: config)
  try await diarizer.prepareModels()

  let result = try await diarizer.process(audioFileURL)
  for segment in result.segments {
      // segment: TimedSpeakerSegment
      // Properties: speakerId ("0", "1"...), startTimeSeconds, endTimeSeconds, embedding: [Float], qualityScore
      print("Speaker \(segment.speakerId): \(segment.startTimeSeconds)s - \(segment.endTimeSeconds)s")
  }
  ```

### 1.4 Speaker Embeddings & `SpeakerManager`
* **Embedding Model:** WeSpeaker v2 producing **256-dimensional L2-normalized `[Float]` vectors**.
* **Pre-Enrolled Speaker Management:** `SpeakerManager` (used in streaming or for matching):
  - `speakerThreshold: Float = 0.65` (maximum cosine distance for assigning to existing profile).
  - `embeddingThreshold: Float = 0.45` (maximum distance to update/refine profile).
  - `minSpeechDuration: 1.0s`, `minEmbeddingUpdateDuration: 2.0s`.
  - `initializeKnownSpeakers([Speaker], mode: .merge, preserveIfPermanent: true)`: Preloads enrolled profiles.
  - `findSpeaker(with: embedding) -> (id: String, distance: Float)`: Fast cosine distance lookup.
* **Sortformer Alternative:** FluidAudio also provides Sortformer diarization for streaming. It has excellent pre-enrolled speaker mapping, but is capped at **4 speakers maximum** and does not persist profiles across separate recordings on its own.

---

## 2. Meetily Repository Deep Dive & Fork-vs-Build Decision

**Repository:** `github.com/Zackriya-Solutions/meetily` (formerly `meeting-minutes`, MIT License)
Inspected files: `CLAUDE.md`, `Cargo.toml`, `frontend/src-tauri/src/audio/*`, directory structure.

### 2.1 Architecture & Tech Stack
* **Framework:** **Tauri 2.x (Rust) + Next.js 14 + React 18**.
* **Audio Engine:** Pure Rust audio pipeline using `cpal` for device capture and custom DSP (`pipeline.rs` with RMS-based ducking and clipping prevention).
* **Transcription:** Uses `whisper-rs` (C++ bindings) and experimental Parakeet paths.
* **Audio Capture Mechanism on macOS:** Implemented in `audio/devices/platform/macos.rs` using Apple's **ScreenCaptureKit**, requiring full Screen Recording permissions.
* **Archived Python Backend:** The old FastAPI / Docker / Python backend under `backend/` is deprecated and archived; the active application is strictly Tauri desktop.
* **Platform Support:** **macOS and Windows only**. There is zero iOS support, and Tauri mobile cannot capture system-level audio.

### 2.2 The Commercial Split: Diarization is Paid
The Meetily README explicitly states:
> *"Meetily PRO is available for users who need enhanced accuracy, advanced exports, custom summary workflows... Speaker diarization is also planned for PRO."*

In the open-source Community Edition, **speaker diarization is absent or stubbed out**.

### 2.3 Verdict: Build Our Own Native Swift App (100% Confirmed)
1. **No iOS:** A desktop-only React/Tauri app cannot fulfill our core requirement of an iPhone app for in-person meetings.
2. **Missing Core Feature:** Diarization and persistent voiceprints (our primary value proposition) are proprietary in Meetily.
3. **Swift-Native Advantage:** Our speech models (FluidAudio CoreML) are written in Swift for the Apple Neural Engine. Bridging them into Rust/Tauri adds IPC serialization overhead and fragility.
4. **Permissions:** Meetily uses ScreenCaptureKit (screen recording prompt). We use Core Audio Process Taps (`AudioHardwareCreateProcessTap`), which only requires audio capture permission.
5. **Reusable Elements:** We can adopt Meetily's prompt templates, VAD-filtered ducking concepts, and meeting-app detection bundle IDs under the MIT license with attribution.

---

## 3. Competitive Landscape & Open-Source Prior Art

### 3.1 Granola Product Deep Dive
* **Philosophy:** "Human in the loop". The user types rough bullet points during the call; the AI merges human notes with transcript timestamps to produce clean structured minutes ("Notes Enhancement").
* **Audio Capture:** Background system audio + mic capture without injecting an annoying Zoom/Teams bot.
* **Platforms:** macOS, Windows, native iOS, Android, and Apple Watch apps.
* **Pricing:** Free tier has unlimited meetings but a **strict rolling 30-day history lock**; Business plan is **$14/user/month** (unlimited history, integrations); Enterprise starts at **$35/user/month**.
* **Top User Complaints (Reddit / HN / Community):**
  1. **Generic "Me" vs. "Them" Tagging:** Users constantly complain that Granola defaults to binary "Me / Them" or generic "Speaker A / Speaker B" tags on multi-person calls. It lacks true persistent voice enrollment.
  2. **No Bot Tradeoff = No Attendee Metadata:** Because it runs client-side without a bot, Granola fails to automatically extract who was on the call from the meeting platform's participant list.
  3. **Privacy Concerns:** Audio and transcripts are uploaded to cloud servers for processing.

### 3.2 Other Notable Open-Source Alternatives
* **Anarlog (`fastrepl/anarlog`, formerly Hyprnote / Char):**
  - Rebranded from Hyprnote -> Char -> Anarlog (9.4k stars, MIT, Rust).
  - Local-first AI meeting notetaker. Captures system audio, supports Ollama / LM Studio local LLMs and SQLite storage. Good inspiration for UI, but desktop-focused.
* **OpenOats (`yazinsai/OpenOats`, MIT, 2.6k stars, Swift):**
  - Open-source meeting note-taker written in Swift using FluidAudio for local transcription. Excellent reference for FluidAudio integration.
* **Meeting Transcriber (`pasrom/meeting-transcriber`, MIT, 202 stars, Swift):**
  - macOS menu bar app that auto-detects Teams, Zoom, and Webex, recording and transcribing with dual-track separation.
* **AudioCap (`insidegui/AudioCap`, BSD-2-Clause, 514 stars, Swift):**
  - The canonical reference implementation for macOS 14.4+ Core Audio process tap audio capture.

---

## 4. Apple Platform Audio & System Capabilities

### 4.1 macOS Audio Capture: Core Audio Process Taps
* **APIs:** Introduced in macOS 14.2, stabilized in 14.4:
  - `CATapDescription(stereoGlobalTapButExcludeProcesses: [ownPID])`
  - `AudioHardwareCreateProcessTap(_:_:)` returns an `AudioObjectID`.
* **Aggregate Device Architecture:** The tap UUID (`kAudioSubTapUIDKey`) must be embedded in an Aggregate Device (`kAudioAggregateDeviceTapListKey`) to read buffers via standard Core Audio IOProcs.
* **Permissions:** Requires `NSAudioCaptureUsageDescription` in `Info.plist`. The system prompt asks for "System Audio Recording" rather than the intrusive "Screen & System Audio Recording" required by ScreenCaptureKit.
* **Bleed & AEC:** When the user is on loudspeakers instead of headphones, far-end voices echo into the mic. FluidAudio provides `LocalVQE` (AEC + noise suppression, 4.8M params, 16 ms latency) using the system audio track as far-end reference.

### 4.2 iOS Audio Capture: Backgrounding & `AudioRecordingIntent`
* **Limitation:** iOS completely forbids third-party apps from capturing audio from other running apps (phone calls, Zoom iOS app). iOS recording is strictly **microphone-only** for in-person meetings or speakerphone calls.
* **iOS 18 `AudioRecordingIntent`:**
  - Apps can conform an `AppIntent` to `AudioRecordingIntent`.
  - Enables starting an audio recording directly from a **Lock Screen Widget, Control Center Control, or Live Activity button** without launching the app into the foreground.
  - Requires pre-granted microphone permission and background mode `audio`.
  - Must write chunks to a shared **App Group container** so both the extension and the main app can access them.

### 4.3 macOS Meeting Detection Heuristics
1. `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device tells when any app engages the microphone.
2. `kAudioProcessPropertyIsRunningInput` (macOS 14.4+) inspects which specific PIDs are recording.
3. Frontmost app bundle IDs match known meeting software: `us.zoom.xos`, `com.microsoft.teams2`, `com.cisco.webexmeetings`, `com.google.Chrome` (with Meet title).
4. Calendar event correlation: Check if a calendar event has a conference link and start time within ±5 minutes of mic activation.

---

## 5. Local LLM Summarization: Apple Foundation Models Framework

* **Availability:** macOS 26 / iOS 26+ via `FoundationModels` framework.
* **Context Window Budget:** Fixed **4,096 tokens** per `LanguageModelSession`. This budget includes system instructions, prompt text, tool schemas, and output tokens. Exceeding it throws `.exceededContextWindowSize`.
* **Guided Generation via Macros:**
  - `@Generable`: Applied to custom Swift structs and enums to force the on-device model to return structured data directly matching the schema.
  - `@Guide`: Adds natural-language constraints and descriptions to individual struct fields.
* **Map-Reduce Architecture for Long Meetings:**
  A 60-minute meeting produces ~8,000–12,000 words (~11,000–16,000 tokens), which exceeds the 4,096 token limit.
  - **Map Step:** Chunk the speaker-attributed transcript into 1,500-token slices (~8–10 minutes of conversation). For each chunk, call the model with a `@Generable` struct extracting topics, key decisions, and action items with owners.
  - **Reduce Step:** Pass the collected partial summaries plus user notes into a final `LanguageModelSession` to assemble the structured minutes.
* **Fallback for Older macOS (15.x):** MLX Swift (`mlx-swift-examples`) running quantized Qwen3-4B or Ollama (`localhost:11434`).

---

## 6. Integrations: Calendar & Parachute Vault

### 6.1 Calendar Integration: EventKit vs. Google API
* **Apple EventKit (Recommended P0):**
  - Access via `EKEventStore.requestFullAccessToEvents()`.
  - Reads all Google accounts already added to macOS/iOS System Settings.
  - **Attendee Extraction:** `EKParticipant.url` exposes the email address via `mailto:` URI (`url.resourceSpecifier`). Organizers also provide `EKParticipant`.
  - Zero OAuth setup, zero verification, zero user limit.
* **Google Calendar API (P2 BYO-Client):**
  - Scope `https://www.googleapis.com/auth/calendar.events.readonly` is classified as a **Sensitive Scope**.
  - Unverified Google Cloud projects are **hard-capped at 100 lifetime users** and display a frightening "Google hasn't verified this app" warning.
  - Verification requires a public Privacy Policy, website, and unlisted YouTube screencast.
  - For a free open-source app, EventKit is vastly superior. Google API should only exist as an optional BYO-OAuth client setting.

### 6.2 Parachute Vault Integration (Verified from `omni-app`)
Inspected local codebase: `/Users/benjaminlife/dev/omni-app/apps/server/src/worker/{fathom.ts, calendar.ts, people.ts, transcript-match.ts}` and desktop Rust client `parachute.rs`.

* **Base Endpoint:** `http://localhost:1940/vault/{vault}/api` (default vault: `default`).
* **Authentication:** `Authorization: Bearer <JWT>` minted via `parachute auth mint-token --scope vault:default:write`.
* **Canonical Path Conventions in Parachute:**
  - Meeting Notes: `vault/meetings/<YYYY-MM-DD>/<slugified-title>`
  - Person Notes: `vault/people/<slugified-name>`
  - Tags: `tags: ["meeting"]` for meetings, `tags: ["person"]` for people.
* **Metadata Schema (matching Prism ingesters):**
  ```json
  {
    "type": "meeting",
    "title": "Engineering Sync",
    "date": "2026-10-13",
    "start": "2026-10-13T10:00:00Z",
    "end": "2026-10-13T10:45:00Z",
    "attendees": ["Ana Lopez", "Ben Life"],
    "attendeeEmails": ["ana@example.com", "ben@example.com"],
    "source": "minutes",
    "source_id": "minutes_uuid_1234",
    "action_items": [
      { "owner": "Ana Lopez", "task": "Ship v1 plan" }
    ]
  }
  ```
* **Graph Linking Conventions:**
  - Meeting -> Person attendee relationship: **`attended-by`** (defined as `export const ATTENDED_BY = "attended-by"` in `calendar.ts`).
  - Meeting -> Transcript relationship: **`has-transcript`**.
  - Link Payload:
    ```json
    PATCH /vault/{vault}/api/notes/{meetingNoteId}
    {
      "links": {
        "add": [
          { "target": "{personNoteId}", "relationship": "attended-by" }
        ]
      },
      "force": true
    }
    ```
* **Conflict Handling:**
  - `POST /vault/{vault}/api/notes` with `"if_exists": "ignore"` returns the existing note if the path already exists, completely avoiding 409 Conflict errors.
  - `PATCH /vault/{vault}/api/notes/{id}` requires `"force": true` or `if_updated_at` to satisfy the mandatory optimistic concurrency check.

### 6.3 Google Docs Export Nuance
* Google Drive's API (`files.create`) **does not natively convert raw `text/markdown` to Google Docs format**.
* **Required Implementation:** Convert the Markdown transcript/summary locally to clean HTML (`text/html`), then upload via `files.create` with `media: { mimeType: "text/html" }` and metadata `{ mimeType: "application/vnd.google-apps.document" }`. Google Drive automatically parses the HTML into a formatted Google Doc with native headings, bolding, and bullet lists.
