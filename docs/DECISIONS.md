# Minutes: Decision Log

Format: `ADR-NNN | Status | Decision | Context / alternatives`. To change a decision, add a new ADR that supersedes it.

| ADR | Status | Decision | Context / alternatives |
|---|---|---|---|
| 001 | Accepted | Build a native Swift app; don't fork Meetily | Meetily (MIT) is Tauri/Rust, macOS/Windows only, diarization in PRO only. We borrow ideas (templates, detection heuristics) with attribution. |
| 002 | Accepted | FluidAudio as the speech stack (Parakeet Ultra default ASR / v3 fallback, offline VBx diarization with calendar speaker count hints, WeSpeaker 256-dim embeddings, Silero VAD) | ANE-optimized, Swift-native, permissive licenses, used by many shipping apps. Ultra provides 2.13% clean LibriSpeech WER. sherpa-onnx is fallback. |
| 003 | Accepted | Minimum macOS 15 / iOS 18 | FluidAudio offline diarization crashes on macOS 14 (Apple BNNS bug). |
| 004 | Accepted | The batch (post-meeting) pipeline is authoritative; the live transcript is a preview | Offline VBx + full-context ASR beats streaming quality. |
| 005 | Accepted | Mac capture = two tracks (mic = Me, system = Them) via Core Audio process taps + AVAudioEngine | Lighter permission than ScreenCaptureKit; makes "Me" attribution near-perfect. |
| 006 | Accepted | GRDB/SQLite storage (FTS5), not SwiftData | Explicit migrations, CLI-testable, BLOB embeddings, full-text search. |
| 007 | Accepted | EventKit first for calendar; Google Calendar API optional later (BYO OAuth) | EventKit exposes attendee names + mailto emails with no OAuth or verification burden. Google Calendar API is a sensitive scope with a 100-user unverified cap. |
| 008 | Accepted (pending MN-0.3) | Speaker ID = cluster centroid vs per-person multi-embedding library, Hungarian one-to-one assignment, auto/suggest thresholds with an attendee bonus | Calibrate thresholds empirically. |
| 009 | Accepted | Pluggable `LLMProvider`; default local (Apple FM or MLX, decided in MN-0.5); cloud only BYO-key opt-in | Local-first goal. |
| 010 | Accepted | Pluggable `ExportAdapter`; Parachute + Markdown are P0; Parachute follows Prism conventions (`vault/meetings/<date>/<slug>`, `vault/people/<slug>`, relationship `attended-by`, `if_exists: "ignore"`) | Matches Prism's ingester dedupe and graph linking pattern. |
| 011 | Accepted | Headless-first: every feature reachable from `minutes-cli` before UI | Lets agents test the pipeline without a GUI. |
| 012 | Accepted | XcodeGen `project.yml` is the source of truth for app projects | Avoids .pbxproj merge conflicts between agents. |

## 2026-10-14: Fail closed on unavailable local recognition and uncommitted exports

Apple Speech is the currently implemented ASR backend; it must set `requiresOnDeviceRecognition` for every request and reject devices/locales without local recognition. There is no implicit cloud opt-in. Trained FluidAudio 0.17.7 diarization/WeSpeaker is now integrated with explicit model setup; Parakeet ASR and measured accuracy/performance remain future work.

Prism HTTP 202 is acceptance, not commitment: keep the durable payload in `awaitingReceipt` and do not invent receipt IDs or committed timestamps. Until a receipt-status endpoint is implemented, bounded automatic or explicit retry can resubmit the same idempotency key. Delivery keys include destination and the whole encoded payload; structured content hashes include actual transcript content and identity provenance.

## 2026-10-14: Calendar integration scope

Implement a read-only EventKit adapter for accounts already configured in Apple Calendar, including Google accounts added through system settings. Direct Google OAuth is outside this change. The CLI lists scoped events and binds an event occurrence to an existing meeting before the app exposes event recording. Calendar invitees remain invited context, never evidence that someone spoke or consented to voice enrollment. Calendar permission requests occur only after explicit user interaction. Tests use value snapshots and temporary databases, without reading a personal calendar.

## 2026-10-14: Durable media imports and untimed text

CLI and application share AudioImportService: decode and validate audio, copy it to a unique managed path, validate the copy, then persist the meeting. Processing failures preserve the recording for retry. Plain-text imports retain their text with unknown timing/speaker identity and no embeddings; the application labels them untimed. Reject plain-text ASR fallback rather than manufacturing timed words or confidence values. Imported pipeline results and meeting status commit in one SQLite transaction.

## 2026-10-14: Native connections and product interface

Direct Google uses external/system-browser native PKCE, selected-calendar reads and Keychain-only credentials. Apple Calendar remains a separate provider. Prism uses a distinct minutes-native client and fails closed until restricted capabilities are verified; client/outbox support does not imply server deployment. The owner paused server changes until the other Prism agent produces a stable revision. Existing queued payloads must never silently follow a changed server or grant.

The Mac application uses adaptive system colors, native navigation/toolbar behavior and genuine Liquid Glass for control surfaces on supported OS versions. Readable note/transcript surfaces remain solid. The icon is original locally rendered geometry, and app-owned preference/file metadata calls are declared in the shared privacy manifest.

Apple Foundation Models summaries are an explicit on-device option. Bounded JSON evidence includes actual timestamps/untimed markers and separate user notes. Native typed generation and evidence-reference validation reject unsupported references. Generated drafts do not create confirmed identities, structured decisions or action owners automatically.

## 2026-10-14: Stable local installation and speech-window recognition

All interactive Mac tests use `~/Applications/Minutes.app`, installed by `scripts/install-local-app.sh` after strict signature verification. Preview copies remain on disk but are unregistered from Launch Services. Screen-recording permission had referred to `build/design-preview/Minutes.app`; an owner-approved Minutes-only ScreenCapture reset and regrant repaired access. Do not routinely reset permissions as part of installing updates. Developer ID signing remains a distribution requirement; local builds are ad-hoc.

Startup restores an existing Google grant without a browser or interactive Keychain access. A saved provider choice respects explicit disconnect and Apple Calendar selection. Absent/locked credentials yield a manual retry, not a new login or hidden prompt.

Hardware system-audio recording exposed a recognition failure: a 31.9-second capture containing a known nine-second stimulus produced no transcript, while its speech-only excerpt transcribed successfully. System track/stimulus waveform correlation was 0.982. Normalize recognition inputs to mono 16 kHz PCM WAV and bound them to diarization speech spans, with 400 ms context and 20-second ownership windows. Add each window's source offset to word timestamps; overlapping context has a single midpoint owner. Temporary speech windows live in a private temporary directory and are removed after success, failure, or cancellation. Preserve the full original source tracks and aligned mix. This is batch recognition, not live transcription, and does not establish long-meeting accuracy or calibrated speaker identity.

### 2026-10-14 — ScreenCaptureKit callback readiness

Unavailable, invalid or zero-sample callbacks do not contain PCM to persist and are skipped, following Apple's ScreenCaptureKit sample validity check. A startup callback must not poison the whole archive. Malformed ready PCM, stream failures, write failures and missing final source tracks still fail capture with original sources preserved. The CoreMedia callback regression reproduces the old failure without opening devices. Ad-hoc build signature changes can also leave macOS ScreenCapture permission pointing to an old code requirement even when its switch is enabled; use normal current-build consent with an explicitly authorized app-scoped reset if required, never weaken signature requirements or alter TCC storage directly.

### 2026-10-14 — Requested capture tracks require continuous coverage

A real399-second controlled capture revealed that ScreenCaptureKit could deliver only26.62seconds of microphone audio while system audio continued. The prior finalizer padded the remainder and reported success. Pin the selected microphone's uniqueID at start; do not silently follow a different default route. Treat>3seconds of one requested source falling behind the other as a sticky live error, checkpoint incomplete state and preserve raw sources. At finalization enforce absolute leading/trailing/internal gap budgets; missing coverage cannot be converted into a successful aligned mix. Actual silent buffers remain valid coverage. Short measured source offsets remain supported. These safeguards detect a failed input; they do not fabricate or recover missing audio.

## 2026-10-14 — Automatic recording completion and remembered voices

Stopping a successful recording prepares notes automatically using the selected local summary engine/template. A grounded, deterministic title suggestion may replace only the exact untitled placeholder created at recording start; calendar and manually edited titles remain authoritative. Empty speech retains audio without inventing a title or notes. Summary-provider failure falls back to clearly labeled extractive notes. Concurrent edits and existing summaries are preserved transactionally. The UI distinguishes audio finalization, speech processing and notes preparation.

Remembered voices are applied at the common processed-meeting persistence boundary and in CLI processing. Automatic identity requires compatible trained embeddings, sufficient consented profile/cluster speech, raw cosine >=0.88 and >=0.12 separation from another candidate. Calendar attendance cannot elevate an acoustic match to automatic identification. Names remain reviewable; no implicit person creation, voice enrollment or biometric export occurs.

## 2026-10-14 — Controlled automatic clustering and stable Mac signing

FluidAudio 0.17.7's default clustering configuration internally permits a maximum cosine distance of0.84. A controlled18-turn two-voice fixture exposed complete overmerging. Explicitly configuring SpeakerManager's distance to0.65 recovered both dominant alternating voices while preserving single-speaker controls; an uncertain2-second fragment remains separate. A stricter0.60 candidate was rejected for splitting a single voice. These controlled checks do not establish general diarization error rate or overlapping-speaker accuracy.

Mac packages now use the owner's Developer ID Application identity and Apple notarization with a local Keychain profile. Keep this identity consistent across updates; ad-hoc re-signing changes privacy/Keychain trust and is unsuitable for installed acceptance builds. Signing/notarization does not replace clean-device, physical-iPhone or long-session acceptance.

## 2026-10-15 — Speaker labels and bounded summary repair

Acoustic cluster labels must reach the ASR merger independently of person recognition. A legacy display projection may replace only blank names or exact internal cluster IDs; explicit transcript edits are authoritative and viewing does not rewrite stored rows. Strong remembered identities continue to use the existing conservative eligibility checks.

On-device summary citation failures receive one bounded retry against unchanged evidence and explicit allowed IDs. The retry must pass the same validation; never add citations to unsupported output. Intro-only speech receives a narrow insufficient-conversation assessment with source text rather than invented meeting conclusions. Actual fictional garden planning exercises meaningful synthesis; offline tests remain independent of model availability.


## 2026-10-15: interrupted capture recovery is explicit and copy-only

A physical iPhone recording exposed a missing Stop control and left an AVAudioFile WAV whose data bytes existed but whose RIFF/data lengths had not been finalized. Persistent phone Stop controls now remain available while scrolling and changing meeting views. Startup marks abandoned starting/recording rows interrupted without touching audio or starting speech processing. Explicit processing validates the app-owned microphone path and exact PCM16 mono 16 kHz layout, then repairs a separate copy with bounded-memory header updates. Unknown layouts fail visibly with originals preserved. This is container recovery, never a claim that interrupted speech is complete.


## 2026-10-15: microphone startup must rebuild unsupported graphs

Physical iPhone build 27 isolated the first-attempt failure to engine start error `kAudioUnitErr_FormatNotSupported` (-10868), before any frames were committed. Reusing the same installed tap/converter after reactivation was insufficient; matching cached bus formats did not prove hardware support. The pending build 28 design creates a fresh engine after activation and uses a native-format tap, converting actual buffer formats into the existing PCM writer. A generation token retires old callbacks before replacement starts. Recovery remains one-shot, pre-frame, within the original startup deadline; a fresh valid native format may replace the cached format on the same input device only while zero frames have been committed. Committed speech is never silently spliced across graph changes. This decision is not a hardware acceptance claim.

## 2026-10-15 — individual no-speech responses and local folder authority

Treat only the observed exact Apple Speech domain/code `kAFAssistantErrorDomain`/1110 as an empty window. This allows remaining windows and bounded retries; arbitrary errors are not swallowed, and speech-coverage checks may still reject incomplete processing. Preserve original audio and expose playback independently of transcript state. Source tests do not substitute for the blocked native acceptance check.

Folder suggestions use installed local sentence embeddings and conservative score/margin abstention. They do not override manual destinations, including Unfiled. Transactional revalidation covers target content, folder definitions, manual examples and membership revision after model work. Seed the basic starter set once, preserving existing custom folders and the owner's deletion choices. Keep folder state device-local until explicit synchronization is implemented.

## 2026-10-16: Source-grounded unanswered issues in local summaries

Apple's on-device structured question schema repeatedly generated unanswered questions from answered negations and copied its guide example, making otherwise useful normal summaries fail evidence validation. Fictional smoke and detailed-release fixtures reproduced this on the actual local model. Normal output now requests grounded claims, with a compact 1–3-point schema for small inputs; explicit unknown-source sentences are retained separately as cited excerpts. The excerpt detector is conservative, language-specific and does not establish general semantic completeness. Existing citation validation remains, personal notes cannot become quoted meeting questions, and reduction excerpts keep all original evidence IDs. No remote model fallback is introduced. Actual model acceptance covers normal speech, short reasons, related tasks, negation, named follow-ups and unresolved bank-sandbox support.

## 2026-10-16: Process aligned capture sources before mixing

A live generated system-audio test proved the clean system track matches its source (correlation 0.985), but mixing it with speaker pickup on the microphone removed approximately six seconds of detected speech. The mixed transcript recovered only 22/45 reference words. A non-silent mixed file and successful summary therefore do not establish transcription completeness. Process timestamp-aligned system and microphone tracks separately, preserve source-specific cluster IDs, and merge their timed utterances. Retain mixed audio for playback. Only long, exact, overlapping cross-source transcript duplicates may be removed; distinct simultaneous speech stays. This does not implement general acoustic echo cancellation. Original tracks remain available.


### 2026-10-16: expose microphone-free Mac audio capture

The native source chooser previously exposed only microphone and combined capture even though the shared capture CLI already supports `--system-only`. Expose Mac audio only in the app, forward `includeMicrophone: false` to ScreenCaptureKit/archive, and skip microphone consent in recording preflight for that source. UI must explicitly state the microphone is off and omit microphone route/echo guidance. This is macOS device capture; it does not add device capture on iOS. Controlled playback tests must verify hardware mute before starting when silent testing is requested, and must not start a microphone capture as a substitute.

## 2026-10-17: Apple Speech for first Mac reverse-teleprompter preview

Use the existing on-device Apple recognizer for the first bounded live text spike rather than introducing EOU model provisioning in the same change. Keep native captions optional, disposable and independent from final saved transcription. Both source feed and history have explicit bounds; unsupported local recognition fails closed. The NSPanel sits below the physical cutout and uses public native glass; it does not emulate an iOS system API. Streaming voice identity and iOS ActivityKit remain subsequent work.

## 2026-10-19: Consolidate drifted speaker clusters; tolerate declined summary chunks

Real 37-minute call audio invalidated the 2026-10-12 expectation that brief fragments are rare enough to review by hand: FluidAudio's streaming clusters produced 24 call and 5 microphone "speakers" for about 4 voices. After diarization, substantial clusters (≥5 s) merge only at cosine distance ≤0.25 (a single drifted voice measured 0.155; two people alternating turns over call audio measured 0.41 and stay separate). Fragments under 5 s have too little audio for a reliable embedding, so, following pyannote's `min_cluster_size`, each joins its most similar substantial cluster on the same track without a distance bound. The SDK's 0.65 assignment bound is unchanged. On the owner's recording this yields 3 call + 1 microphone speakers. A real speaker with under 5 s of total speech is absorbed into the closest voice — a deliberate trade-off.

Apple's on-device model returned `refusal` for individual 2 KB chunks (mostly intermediate draft notes), which previously discarded the entire summary. A declined first-pass chunk is now skipped and disclosed in the notes (the summary fails if fewer than half succeed). A declined reduction chunk carries its already-validated inputs forward. Reduction prompts use the 1–3 claim schema so each pass contracts. Invented citations are still rejected.

A recording started without a calendar choice is bound to the single invited event in progress (or starting within 5 minutes); overlapping events are left unbound. Saved recordings without an event can be linked afterwards from the notes view.

## 2026-10-19: Compact recording storage; keep distinct short speakers; structured on-device notes

Captures were stored as 48 kHz Float32 originals plus aligned and mixed copies (2.1 GB for a 37-minute call). After processing (successful or not — the owner verified Regenerate from the compressed copy, so uncompressed audio has no remaining use), and in the background after launch for recordings saved by earlier versions, Minutes re-encodes only what playback and Regenerate read (`mixed`, `aligned-system`, `aligned-microphone`) as mono AAC at 24 kHz/48 kbps (16 kHz sources stay 16 kHz), rewrites `capture.json` to `mixed.m4a`, and removes originals only after every encoded file decodes to the source length (a click stays within 10 ms). The real call compacted to 41 MB in under 10 s; diarization of the compressed tracks matched the originals. Only files inside the library's managed `audio` folder are ever rewritten or deleted; imported originals and interrupted recordings (whose recovery expects the WAV) are left alone. Deleting audio clears `audio_path` explicitly (`saveMeeting` keeps COALESCE protection) and keeps transcript, speakers and notes; Regenerate then explains that the audio is gone. Settings → Storage (Mac and iOS) and `minutes-cli audio` expose usage, compression and deletion.

The owner asked for more generous diarization. Keeping every 2 s fragment would have produced 13 speakers on the reference call, so a cluster with 2–5 s of speech stays separate only when it is unlike every substantial voice (cosine distance ≥ 0.9); fragments under 2 s and similar short clusters still join their closest voice. Reference call: 5 call + 2 microphone speakers.

On-device notes for multi-chunk meetings now render an overview, model-extracted decisions and action items (dedicated schema with empty lists allowed, every line citation-checked; extracted from section-level notes because on raw transcript chunks the local model copied speech — ~100 lines including "Yeah" — instead of stating outcomes; questions, fragments, run-ons and copied speech are dropped, and explicit will/should commitments are listed as actions) and chronological discussion sections taken from the first summary level with at most 8 chunks, headed by time range and the transcript's own key phrase. Short meetings keep the plain bullet layout.
