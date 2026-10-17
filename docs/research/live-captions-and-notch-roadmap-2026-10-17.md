# Local live captions, speaker names and a camera-adjacent UI

Research date: **2026-10-17**. Research only; no production implementation, model download, audio playback, app launch or measured benchmark was performed. “Available API” means present in the inspected dependency/public documentation. Performance targets below are proposed gates, not results.

## Recommendation

Build future live captions in three separable steps: local streaming text; provisional local speaker attribution; then an optional **Mac camera-adjacent panel**. Use an ordinary draggable caption window near the webcam/notch, with a menu-bar fallback. The physical Mac notch is a camera cutout, not a programmable screen. On iPhone, use a Live Activity for recording status and brief completed text where practical; continuous captions belong in Minutes' own screen. Do not promise an arbitrary floating caption strip above other iOS apps.

Keep the current batch/review transcript as the saved source of truth. A streaming model's “final” means a local decoding/timeline decision, not that a human identity is certain or that the offline pipeline cannot correct it.

## Actual repository and FluidAudio baseline

The package resolves **FluidAudio 0.17.7**, revision `503b4bd1bbf7220882de39fe8ae6716aae4132da` in `MinutesKit/Package.resolved`. The installed checkout was inspected directly. The current `MinutesSpeech/ASRService.swift` uses Apple's `SFSpeechRecognizer` with on-device recognition requirements; this is not an existing FluidAudio live-ASR integration. The current `FluidDiarizationBackend.swift` uses `DiarizerManager` for completed audio and explicitly configured automatic clustering; the old research description of universal VBx processing does not describe every current code path.

| Inspected API at pinned revision | What is proven | Implication |
|---|---|---|
| `StreamingEouAsrManager` actor | `loadModels`, `appendAudio(_:)`, `process(audioBuffer:)`, `finish()`, `reset()`; partial and EOU callbacks | Real incremental local ASR is available; Minutes still needs capture-buffer plumbing and lifecycle ownership |
| `setPartialCallback` / `setEouCallback` | Both receive accumulated strings | Handle replacement/revision explicitly; callbacks are not a stream of immutable word records |
| `getTokenTimestampsMs`, `getRawTokenStrings`, `getEouTimestampsMs` | Timestamp/token inspection APIs | Establish stable session offsets and word joining before aligning captions with speaker segments |
| `StreamingChunkSize` | 160 ms, 320 ms, 1280 ms model configurations | Chunk size is not end-to-end visible caption latency |
| `eouDebounceMs` | Default 1280 ms | A “<200 ms final text” promise is unsupported even before inference and UI scheduling |
| `DiarizerManager` | `initializeKnownSpeakers([Speaker])`; `extractSpeakerEmbedding(from:)`; `performCompleteDiarization` | WeSpeaker profiles can inform a matching path, but rolling operation needs separate validation |
| `SortformerDiarizer` | `addAudio`, `process() → DiarizerTimelineUpdate?`, `finalizeSession`; fixed four speaker slots | A real streaming diarizer exists, with a hard speaker-capacity tradeoff |
| `DiarizerTimelineUpdate` | Separate `tentativeSegments` and `finalizedSegments` | UI and merger must distinguish mutable tail from committed diarization |
| Sortformer `enrollSpeaker(withAudio:…named:)` | Primes state from audio, not a stored WeSpeaker vector | Do not claim stored 256-dimensional vectors can directly initialize Sortformer slots |

Pinned upstream sources: [EOU manager](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/ASR/Parakeet/Streaming/EOU/StreamingEouAsrManager.swift), [Diarizer manager](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/Diarizer/Core/DiarizerManager.swift), [Sortformer](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/Diarizer/Sortformer/SortformerDiarizer.swift), [Sortformer config](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/Diarizer/Sortformer/SortformerTypes.swift), [timeline](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/Diarizer/DiarizerTimeline.swift).

These findings come from the local pinned source, not assumptions about the latest README. Upstream comments advertise performance figures, but they are not measurements of Minutes, this microphone, or iPhone thermals. EOU is the English-first option described by the project's research; any multilingual streaming mode must be evaluated independently.

## ASR and named-speaker design

Proposed pipeline: capture writes crash-safe audio first, then bounded resampled mono 16 kHz buffers feed independent ASR and diarization actors. A monotonic recording sample clock anchors all outputs. Inference must not run on the realtime audio callback or main UI executor. Backpressure may drop/restart the disposable preview, never the durable recording.

### Preview states

| State | Presentation | Persistence rule |
|---|---|---|
| ASR partial | Muted tail text; may change | Ephemeral |
| EOU text | Stable-looking completed phrase | Still a live preview; batch can revise |
| Anonymous diarization | “Speaker 1”, “Speaker 2” | Session-local identity only |
| Candidate match | “Ana?” or neutral suggestion indicator | Not a confirmed identity |
| Confident provisional match | Name plus accessible preview indication | Never enroll/update a voice automatically from this output |
| Overlap/uncertain | “Multiple speakers” or unassigned text | Avoid forced identity or fabricated word separation |
| After meeting | Batch processing + existing review flow | User-confirmed assignments and saved transcript govern exports |

ASR does not inherently separate two simultaneous voices, even when diarization detects overlap. Keep per-speaker intervals and allow multiple active speakers. Single mixed-channel words cannot always be assigned reliably. Mac mic/system separation can help, but mic bleed and speakerphone audio still need handling. Calendar attendance narrows a candidate list; it is not proof of acoustic identity.

### Two diarization routes worth comparing

**Route A: rolling WeSpeaker extraction and Minutes matching.** Use the same model family as existing profiles. Segment clean speech, extract embeddings, then use the current matcher with conservative abstention and a duration/margin policy specifically calibrated for streaming. Default `DiarizerConfig` has a ten-second chunk and one-second minimum speech; do not assume it gives immediate labels. Shorter windows can reduce quality. Avoid repeatedly processing an ever-growing full recording. Cache only bounded PCM and carry session identity explicitly across windows.

**Route B: Sortformer segmentation plus separate WeSpeaker identity.** Sortformer supplies streaming speaker activity; accumulate nonoverlapping, high-quality speech per slot and extract compatible WeSpeaker vectors to match saved profiles. Its four slots are not a four-person universal meeting guarantee: slot reuse, speaker churn and >4-person meetings need an explicit fallback. An alternative is priming Sortformer with separately consented enrollment audio, but existing vector-only profiles cannot reconstruct that audio. Keeping sample audio solely to enable priming is a new retention decision, not a hidden requirement of existing voiceprints.

Route A is the lower integration-risk initial spike because current identity storage is model-tagged WeSpeaker. Route B may give better turn continuity but adds another model and a second identity layer. Measure both on the same licensed/consented recordings before choosing. “Confident provisional match” needs calibrated error rates; model quality scores and raw cosine similarity are not probabilities.

### Memory and latency gates

At 16 kHz mono Float32, ten seconds of PCM is about **0.64 MB**, one hour about **230.4 MB** (decimal), before arrays/copies/model memory. These are calculated storage sizes, not resident-memory measurements. The implementation must bound queues, retained waveform samples and diarization history (`maxStoredFrames`, `storeSegments`), and discard preview buffers after use. Loading EOU + diarization + embedding models concurrently can dominate RAM; file sizes do not establish process peak memory.

Measure separately: capture-buffer age; inference time; first partial; text stabilization; speaker-turn detection; first proposed name; corrected name; UI delivery; CPU/ANE contention; peak physical footprint; thermal state; power/battery drift. Include cold model load and warm steady state, one and four speakers, noise, short interjections, overlap, and a sixty-minute session.

Proposed initial goals: warm first partial p95 ≤2 s; preview processing faster than realtime without an increasing queue; no recording loss when preview is disabled/restarted; named attribution may lag by several seconds to collect useful evidence. A false confident name is worse than an anonymous speaker. Do not carry the PRD's desired recognition percentages forward as achieved performance. Define a held-out wrong-name rate before releasing automatic labels.

## Mac: camera-adjacent captions with public AppKit

Use an app-owned `NSPanel`/`NSWindow` hosting SwiftUI. A nonactivating panel can offer glanceable captions without changing the meeting app's keyboard focus; a normal window remains available for selection and history. Public panel/window APIs support the basic form. [NSPanel](https://developer.apple.com/documentation/appkit/nspanel), [floating panel behavior](https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel).

Position content **below or beside** the camera cutout using the selected display's `safeAreaInsets` and auxiliary top-area geometry, rather than assuming a fixed notch width, height or screen origin. Recompute on display arrangement, scale, menu-bar and desktop changes. Ordinary external displays get the same small top-centered window. No API here makes physical camera hardware display text. [NSScreen safe area](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets), [auxiliary top-left area](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc).

Spaces/fullscreen behavior is a separate spike: `canJoinAllSpaces`, `fullScreenAuxiliary` and panel level are candidates, not a promise that arbitrary overlays are visible over every app, system surface, Stage Manager arrangement or fullscreen mode. Avoid aggressive window levels that cover security UI or steal focus. Provide a menu-bar “Show captions” action and a regular caption window when the preferred position is unavailable. [Window collection behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct), [fullscreen auxiliary behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary).

Proposed UX: two stable caption lines, optional speaker label, a compact recording-status control and a clear expand/close gesture. Expand into a conventional draggable panel; reserve fixed space to avoid every phrase moving the window. Let the user choose monitor and position. Screen sharing may include the panel depending on capture method: warn in the share workflow or document actual observed behavior; do not claim universal invisibility. A notch position keeps eyes near the webcam but does not establish improved eye contact without user testing.

## iPhone: Dynamic Island is a system presentation

Live Activities use ActivityKit, WidgetKit and SwiftUI. The system selects compact, minimal, expanded and Lock Screen presentations; a competing activity may reduce visible space. The activity extension cannot fetch network data itself. Combined state is limited to 4 KB and an activity generally lasts up to eight hours. Keep the island's payload to status, elapsed-time anchor, a short completed phrase when feasible and explicit actions. Full transcript belongs in the app. [Live Activity architecture and constraints](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

Do not send one push per word. Apple describes a variable high-priority push budget, throttling, optional frequent-update support and user controls. `NSSupportsLiveActivitiesFrequentUpdates` raises permitted push activity under the documented conditions; it does not guarantee an unlimited realtime text surface. Low-priority pushes are opportunistic. Distinguish this server-push budget from local `Activity.update` calls while the app has legitimate execution time; neither is a contractual per-word rendering guarantee. [Apple WWDC: Live Activity push updates](https://developer.apple.com/videos/play/wwdc2023/10185/).

Recording with background audio mode can keep an authorized microphone recording alive while locked, subject to interruptions and routing. A Live Activity does not itself grant background compute time or mic access. iOS does not let Minutes capture another app's active call microphone; this limitation remains even if a Dynamic Island activity is present. [Background recording category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [active-call recording restriction](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:)).

Picture in Picture is documented for media playback and video-call content. It is not a general entitlement for an arbitrary transparent floating caption UI. Do not use dummy video, hidden playback or a fake call to manufacture cross-app overlays. Whether a genuine future Minutes video-call/media feature qualifies would require its own product and review investigation. [Apple video-call PiP](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls), [PiP content source](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class).

## Animation and accessibility

Proposed animation is a quiet phrase transition, not a continuously pulsing island or a fake audio waveform. On Mac use a short opacity transition or optional small expansion; honor Reduce Motion and Reduce Transparency. Preserve readable text contrast over any app. Speaker names need text/symbol cues in addition to color. Enable text resizing, keyboard navigation and an accessible “Live preview; names may change” description. VoiceOver should announce completed phrases only when explicitly enabled, not every token. Captions must remain useful with animations disabled and in reduced-luminance/Always On conditions. [Apple Live Activities design](https://developer.apple.com/design/human-interface-guidelines/live-activities), [SwiftUI Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion).

These are public-API-aligned design choices, not App Review preapproval. Describe the feature as “optional live local preview” until accuracy and platform behavior are measured.

## Proposed implementation order and exit criteria

1. **CLI streaming file spike:** replay a fixture in timed buffers into EOU, with partial/EOU events and timestamps; no UI or live microphone needed. Show bounded queue behavior, flush/reset and alignment across interruptions.
2. **Identity spike:** compare rolling WeSpeaker and Sortformer-plus-WeSpeaker using saved profiles; evaluate unknowns, overlap, speaker churn and >4 participants. Report name precision, abstention, changes and latency separately.
3. **Mac caption window spike:** test nonactivating focus, notch/non-notch displays, two displays, Spaces, fullscreen, Stage Manager and screen sharing. Gate on useful fallback behavior, not an “always above everything” claim.
4. **iPhone status activity spike:** explicit microphone start/stop, locked-screen recording, interruption, app suspension/termination and stale-state behavior. Evaluate latest completed phrase experimentally; do not require word-by-word Island captions.
5. **Endurance and accessibility:** sixty-minute recording while preview runs; power/thermal budget; no data loss; clear recovery; Reduce Motion, large text and VoiceOver review. Only then update ARCHITECTURE/DECISIONS with measured behavior.

No new cloud service is required for the local preview. Optional server capture and optional voiceprint synchronization remain separate consent and architecture decisions; see [capture roadmap](meeting-bot-roadmap-2026-10-17.md) and [voiceprint sync](voiceprint-sync-options-2026-10-17.md).
