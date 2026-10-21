# Minutes: implementation status

Updated 2026-10-15 after integrated native repairs and initial physical iPhone deployment. Earlier “100% Complete” milestone labels overstated delivery. Compilation and synthetic/unit fixtures do not establish microphone reliability, speaker recognition accuracy, iOS background recording, live Prism compatibility, clean-install validation, or release readiness.

- `[x]` implemented and checked within the evidence stated below.
- `[~]` partially implemented; required integration or acceptance work remains.
- `[ ]` missing or not demonstrated.
- `[!]` requires owner credentials or physical-device release validation.

## 2026-10-16 identity and invitation review

- [x] Repair duplicate calendar self/name/RSVP context and retain invitation response through binding and SQLite reopen, using an additive migration and historical JSON compatibility.
- [x] Display RSVP as invitation context, distinguish remembered/unconfirmed speaker matches from confirmed names, and remove the claim that suggested invitees are present.
- [x] Reverify installed trained-model voice enrollment → persistence/reopen → independent automatic reuse for two generated voices, with wrong-person attendee rejection. 47 targeted model-free tests plus the real-model acceptance passed; full sandbox speech-suite run stalled and was terminated, not counted as passing.
- [ ] Real-human recognition accuracy, overlapping/noisy calls and cross-device voice profile sync remain unverified. No install, live recording/playback or personal calendar actions in this audit.

2026-10-16: Details, evidence paths and exact test commands: `audit/identity-calendar-review-2026-10-16.md`.

## 2026-10-15 source 31: desktop audio / folder repair

- [x] Strong nonempty PCM verified in the owner's reported 74.65-second system recording; capture and transcription failure are now distinguished. Numeric-only diagnostics; no transcript or voice-vector logging.
- [x] Recognition's exact no-speech-window response no longer aborts later windows and bounded retries. Other errors and missing substantial-speech coverage still fail visibly.
- [x] Saved-audio player is visible without transcript; playback is guarded during capture across saved audio, transcript and speaker samples.
- [x] One-time Work/Personal/Learning starter folders preserve custom libraries and deleted-starter choices. Native drag transport replaced with label-level item providers, batch validation and atomic filing; source no longer scrolls on pointer selection.
- [x] Full regression: 297 reported tests passed (configured optional skips); physical iPhone 31 compiled; Mac 31 Developer ID package/signature verified.
- [~] Mac locked before native idle/quit/install and actual drag/saved-audio/capture acceptance. Installed Mac 30 left untouched. Build 31 is locally signed, not notarized; Minutes-Notary profile remains unavailable. iPhone 31 is compiled, not installed.
- [ ] iOS device-audio adapter: Apple iOS 27 ScreenCaptureKit research establishes a possible media-capture path, but current iPhone app remains microphone-only and another app's live call audio is unsupported.

## Folders and on-device filing (2026-10-15)

- [x] Notes-style Upcoming/People group, separate local meeting folders/counts, folder creation/edit/removal, scoped libraries, Move menus and drag/drop targets on Mac/iOS. Folder deletion preserves meetings; multi-note moves are atomic.
- [x] Native installed sentence embeddings compare every folder and manual examples. Weak/ambiguous matches abstain. Actual fictional local-model and CLI checks passed; manual choices and async edits are protected.
- [x] Integrated suite reports 286 passing tests with gated live/model checks skipped by default; iPhone build 30 compiled/signed/installed; launch was blocked by the locked phone and needs the owner to open it.
- [~] Physical folder interaction/visual acceptance still pending. Mac 30 Developer ID signing passed, but notarization profile is unavailable; Mac 30 is installed locally with verified Developer ID signing (not notarized); release notarization awaits owner credential restoration. Native drag did not commit a move in build 30 and is being repaired in source 31.
- [ ] Folder/library synchronization between devices or through Prism is not implemented. Folder state is local.

[Folder implementation/evidence](../audit-2026-10-14/18-FOLDERS-AND-LOCAL-FILING.md).

## Calendar, remembered voices and physical iPhone (2026-10-15)

- [x] Shared Calendar agenda and event detail, exact-email person reuse, bounded per-person call history with explicit invitee/confirmed/recognized distinctions; CLI and temporary-database verification passed.
- [x] Actual trained voice enrollment, database reopen, independent-clip recognition, transcript label persistence and wrong-speaker abstention passed using two generated speakers. This does not establish real-human accuracy or cross-device synchronization.
- [x] Integrated source build 22: 241 reported tests across seven test runs passed (opt-in model/live tests skipped as configured). Mac build 22 Developer ID signing, notarization, stapling and Gatekeeper passed. iPhone build 21 installed on the owner's physical device; build 22 device compilation passed.
- [x] Owner confirmed physical iPhone Calendar sync, then build 24 first-attempt recording, Stop, transcription and summary generation. Repaired missing Stop, unconditional healthy-engine notification failures, interrupted WAV copy recovery and recovery retry persistence. Source now honors the owner’s preference for a single card Stop action.
- [~] Summary quality needs owner acceptance. Final controlled native fixtures preserve the substantive discussion’s decision, follow-ups and unresolved question, and the brief clip’s stated reason. These do not establish arbitrary conversation or phone-model quality.
- [~] Later physical testing reproduced a transient startup halt with zero frames and unchanged input/format. Build 26 diagnostics show its bounded restart also failed immediately. Build 27 explicitly reactivates the iOS audio session before recovery, revalidates the graph/deadline, and records safe failure stage/domain/code. All 265 reported offline tests passed and the physical iPhone build compiled, verified, installed and launched. The owner reproduced the failure on build 27; diagnostics now identify engine-start error -10868 (unsupported format), zero committed frames. Build 28 now reconstructs the iOS graph with native-format taps, generation-isolated callbacks and the same writer/startup deadline. It also reduces requested tap batches to 1024 and advances waveform history during steady volume. All 269 offline tests and device compilation/signature/installation passed; independent lifecycle review cleared the source. The owner confirmed first recording works in build 28; its trace verifies 14.299 seconds and no capture error. Waveform lag persisted in 28. Build 29 isolates 20 Hz samples in a dedicated meter publisher/readout and draws one Canvas; regression verifies zero app-wide redraw notifications for 18 within-second meter updates and exact finalized Stop duration. All 271 reported offline tests and physical-device build/signature/installation passed; The owner confirmed build 29 waveform is responsive and recording works; its trace verifies 10.999 seconds/110 buffers with no failure. Broader long/background/route acceptance remains open.
- [ ] Longer/background phone recording and real-human remembered-voice reuse remain acceptance gates. Voice profiles do not sync through Prism.

## Extended recording, local completion and signed glass revision (2026-10-14)

- [x] Reproduced and repaired long microphone dropout: signed native repeat captured 372.55 seconds with complete 48 kHz system/microphone tracks, no manifest issues, and first/last generated speech on both tracks.
- [x] Repaired automatic clustering overmerge with actual installed-model controls; native long repeat transcribed all 18 generated turns and correctly separated both dominant voices. A tiny uncertain third fragment remains; synthetic results are not general speaker/overlap accuracy.
- [x] Automatic local notes and grounded placeholder-only title after recording; empty speech, provider fallback, existing/manual/concurrent edits protected by regressions.
- [x] Strong remembered-voice prefilling with compatible learned profiles, acoustic ambiguity rejection and no implicit enrollment. Identical-evidence human choices survive retry; changed analysis requires review.
- [x] Refined centered pre-record composition, spacious glass Record pill, material-backed toolbars, inset sidebar and native editing/review surfaces. Saved reprocessing explicitly communicates replacement of transcript/speaker analysis.
- [x] Developer ID signing identity and local notarization profile configured; build 6 Apple notarization, stapling and Gatekeeper verification passed. Final source: 206 reported Swift tests, four expected opt-in skips; iOS Simulator build passed.
- [x] Final build 8 signed, notarized, stapled, Gatekeeper accepted and installed at the stable app path. Native two-source recording automatically produced title/notes and two voice clusters. Synthetic staging export returned a committed server receipt. Google actual expired-token refresh and clean restart passed after one-time owner Keychain approval; Google/Prism restored in build 8.
- [ ] Physical iPhone, clean-device and hour-long real-human/overlap/route-change acceptance remain open. The owner changed playback speakers after opening words during a synthetic test; that affected opening is not classified as a transcription failure.

[Detailed evidence and limits](../audit-2026-10-14/15-EXTENDED-CAPTURE-AND-NATIVE-REFINEMENT.md). The sections below retain historical milestones.

## Hardware capture and restart recovery (2026-10-14)

- [x] Stable local install at `~/Applications/Minutes.app`; backed-up upgrades, workspace preview unregistration and exact executable path verified after macOS permission restart.
- [x] Saved Google grant restores on launch without a browser or Keychain prompt; installed build 3 read the real Calendar API after launch, and final build 4 remained connected after a clean quit/relaunch. Explicit disconnect/Apple provider choices are respected. Five startup regression tests pass.
- [x] Removed duplicate toolbar Record icon and custom clipped toolbar sizing; native toolbar metrics and increased document spacing. Saved recordings can be transcribed again from Meeting actions.
- [x] Actual system/microphone tracks captured in build 3; generated stimulus matched the system track at 0.982 normalized correlation.
- [x] Repaired empty whole-recording recognition by using bounded speech windows with source timestamp restoration. Installed build 4 correctly transcribed the original untrimmed system recording at 11.6775 seconds.
- [x] Fresh built-in microphone recording in build 4 captured and transcribed generated speech with one speaker cluster; no app crash.
- [x] Build 5 repaired a native ScreenCaptureKit startup callback failure. Actual system-plus-microphone capture → finalization → transcription passed: 25.5 seconds, both 48 kHz tracks, no manifest issues, expected sentence, one cluster/utterance. Permissions and Google/Prism connections survived a clean restart. Full suite: 175 discovered, 172 passed, three opt-in skips; strict Mac package validation passed. This historical build used ad-hoc signing; Developer ID signing/notarization is now configured as recorded above.
- [ ] Real expired-token refresh, multi-speaker accuracy, long-session/route changes and physical iPhone acceptance remain open.

Prior build 4 suite: 174 discovered, 171 passed, three opt-in skips; Mac build 4 signature/privacy/package and iOS Simulator build passed. Final build 5 verification is recorded above. Current local app: `~/Applications/Minutes.app`. [Evidence and limits](../audit-2026-10-14/14-HARDWARE-AND-RECONNECT.md). Earlier sections below are historical snapshots.

## Mac mini staging and Notes reference revision

2026-10-14: Deployed isolated Prism staging to `https://minutes.omniharmonic.com` with a dedicated tunnel, loopback service and `minutes-staging-20261014` vault. Public TLS/401 boundaries and host-scoped vault access passed; main Prism remains unchanged. Mac and iPhone layouts were revised using the supplied Apple Notes references; both build. Live sign-in exposed a Swift actor-isolation crash in the system-browser completion; explicit Sendable callback isolation and a background-delivery regression test address it. Native Safari sign-in, persisted restricted Keychain grant, actual synthetic vault export, unchanged deduplication and edited revision 2 acceptance passed. Final native glass toolbar/sidebar revision builds and strict signature verification pass; see the [current deployment report](../audit-2026-10-14/12-MAC-MINI-DEPLOYMENT.md).

## Notes-first redesign and Prism follow-up

2026-10-14: Replaced the rejected card/dashboard layout with true native three-column navigation, plain editable notes, native toolbar search/share, a recording popover and standard Cmd-comma Settings tabs. Simplified transcript/speaker/People review. Final package UI checks verified title/note persistence, older-meeting selection and immediate search of saved notes with fictional fixtures. Public OAuth fields remain available under Advanced.

Prism work resumed on stable `288ce029`: dedicated selected-vault grants, restricted native client, durable imports/receipts and session-cookie confinement are implemented. Real native Swift→local Prism HTTP acceptance passed. Source applied to the active Prism checkout; production service/DNS/TLS and live vault consent remain pending. User notes and summary evidence provenance were corrected in export payloads.

Final checks: 151 Swift definitions, 148 passed and three opt-in skips; HTTP acceptance separately passed. Native Mac release/iOS Simulator builds, strict ad-hoc signature and ZIP checks passed. Current package: `build/notes-first-2026-10-14/Minutes.app`. [Report](../audit-2026-10-14/11-NOTES-FIRST-AND-PRISM.md).

## Previous continuation: capture, connections and visual design

- [x] Native Mac visual upgrade: adaptive system colors, native navigation/toolbars, real Liquid Glass control surfaces on supported OS versions, solid note/transcript surfaces, explicit search, editable summary Markdown, original app icon and privacy/resource metadata. Running-app recorder/connection controls inspected with an isolated synthetic library.
- [~] Mac call audio: ScreenCaptureKit system + microphone sources, timing manifests and aligned processing copy are implemented and covered by 12 source/parser tests plus 3 AppState flow tests. Physical permissions, actual two-machine call capture, route changes, long-session reliability and crash-recovery acceptance remain unverified.
- [~] Direct Google native PKCE/API connection, Keychain credentials, refresh/revoke, pagination and native controls are implemented. Public client IDs, real consent, account permissions and calendar integration acceptance remain pending; system Calendar is still separately supported.
- [~] Native restricted Prism sign-in/capability/queue controls are implemented. Origin, grant and revision safeguards are covered by synthetic tests. The owner paused **all Prism server changes/deployment** until a separate agent finishes a stable server revision; no server integration or public-domain readiness is claimed.
- [~] Optional Apple Foundation Models summaries are implemented with availability checks, bounded/cited typed generation and four generated-note formats. A fictional native request passed after two freeform outputs were correctly rejected. Generated drafts still require review; long-meeting quality/performance remain unmeasured. Extractive notes remain the explicit default.
- [~] Configured Mac notarization/stapling/Gatekeeper flow and native iOS resources are prepared. Developer ID/notary profile, Team/provisioning, physical devices and production acceptance are still required. Final integrated Swift checks passed: 148 discovered test definitions, 146 passed, two explicitly opt-in model tests skipped. The regenerated iOS simulator target built successfully; production signing and physical-device acceptance remain pending. Current local-test app: `build/production-pass-2026-10-14/Minutes.app`. Package evidence is recorded in the continuation report; the repair-package paths below are historical.

Setup: [Google](docs/GOOGLE_CALENDAR_SETUP.md), [Prism](docs/PRISM_CONNECTION_SETUP.md), [Apple/device/release inputs](docs/RELEASE_SETUP.md). Current continuation report: `../audit-2026-10-14/10-PRODUCTION-PASS.md`.

## Verified foundations and second-audit repairs

- [x] Swift package builds shared modules, a macOS SwiftUI executable, and `minutes-cli`.
- [x] SQLite persistence, meeting-scoped attendees, acoustic clustering/merger helpers, speaker matching, notes/bookmarks, Markdown export, and mock-transport Prism tests exist. Tests verify specific behavior; they do not establish the full PRD acceptance criteria.
- [x] Removed fabricated production transcript/summary outputs in prior work; normal processing uses decoded audio. Unused application demo/sample loaders that wrote fictional contacts and vectors into the normal store were removed.
- [x] **2026-10-14 repair: local recognition fails closed.** Apple Speech requests always require on-device recognition; an unsupported locale/device fails before recognition rather than silently allowing server recognition. Request-policy tests cover both branches. Apple Speech transcription permission and actual speech decoding were not exercised; the trained diarization smoke below is separate.
- [x] **2026-10-14 repair: recording failures are visible.** Start reports active recording only after recorder startup and meeting persistence succeed. Stop errors/missing or invalid finalized audio mark the meeting failed and avoid processing. App state supports injected storage/recorders for isolated error-path tests. Hardware capture remains unverified. Recorder writes now retain the first I/O/conversion failure, count only committed frames, close files before processing, and stop via the UI error path. Capture teardown no longer holds a callback lock while waiting for audio callbacks.
- [x] **2026-10-14 repair: Prism content identity.** Structured hashing includes transcript text/timestamps/speaker identity and people details. Delivery keys additionally include destination vault and the complete encoded payload, so transcript edits and distinct vault destinations are no longer collapsed.
- [x] **2026-10-14 repair: speaker provenance.** Prism speaker IDs resolve through meeting clusters and exported people. Unresolved speakers remain unassigned instead of exporting display names as confirmed IDs.
- [x] **2026-10-14 repair: honest receipts.** HTTP 202 enters `awaitingReceipt` without a fabricated committed receipt. HTTP 200/201 require actual committed receipt IDs and server revision. Pending receipts are retried with the same idempotent payload and bounded exponential backoff; a dedicated receipt-status endpoint remains unimplemented.

- [x] **2026-10-14 durability follow-up:** attendee/cluster/utterance batches are transactional and throw on SQLite prepare/step failures; invalid rows roll back preceding successful rows. Summary constraint failures now throw. Text bindings copy their values safely in these write paths.
- [x] **2026-10-14 startup follow-up:** configured storage failures block startup with an explicit error and retry control. There is no silent temporary/in-memory database fallback.
- [x] **2026-10-14 outbox recovery follow-up:** atomic enqueue deduplication and conditional SQLite claims coordinate independent connections. Stale sends recover after a 120-second lease with their original key; late receipts cannot overwrite cancelled/reclaimed rows. Pending receipts retry idempotently, automatic attempts honor the configured retry ceiling, and persistence failures propagate to callers.

## Incomplete product gates

- [~] **Speech stack:** current ASR is Apple Speech, not Parakeet. Trained FluidAudio 0.17.7 segmentation/WeSpeaker integration and explicit local model setup were added; normal processing requires installed, verified models. An explicitly enabled smoke downloaded pinned model weights to isolated temporary storage and ran real trained diarization on a public SDK fixture; setup-disabled inference also passed. Apple Speech ASR and accuracy benchmarks remain unverified. No held-out WER/DER, identity precision/abstention, runtime, or memory acceptance evidence.
- [~] **Capture:** microphone PCM and optional ScreenCaptureKit call-audio recording exist. Separate native source tracks share timing metadata and render an aligned 48 kHz processing copy; this is not the original CoreAudio process-tap design. Full durable crash recovery and demonstrated hardware/device/route/interruption acceptance remain unfinished. Injected disk-write failure tests verify error retention and committed-frame accounting. Physical disk-full recording, route changes and long-session capture remain unverified.
- [~] **Persistence:** batch write errors and startup storage failures now propagate explicitly. Pipeline result/status commits are transactional. Persisted artifacts/steps/edit revisions and resumable jobs remain absent; these remain release blockers.
- [~] **Learning/review:** model provenance now separates trained vectors from legacy spectral/demo data. CLI learning requires `--learn`; app learning defaults off and applies only to the chosen confirmed compatible cluster. Real cross-session recognition and correction/revocation lineage remain unproven; current suggestions must not be described as calibrated speaker identity.
- [~] **Prism outbox:** native connection/capability controls and mock URLSession tests cover delivery/error states. No live server contract or vault write was tested. Recovery claims, bounded retries and cancellation-preserving receipt updates are covered by tests. A dedicated receipt polling contract and live server acceptance remain incomplete; local queues and cached capabilities now bind to a specific device grant. Cancellation preserves the local revoked state but cannot undo an upload already accepted remotely. The native outbox is now the app's Parachute/Prism export flow, requiring restricted capability verification; the legacy CLI adapter is explicitly separate.
- [~] **Calendar:** read-only EventKit provider, scoped event/participant snapshots, occurrence-aware suppression, transactional meeting/invitee binding, CLI `events`/`bind-event`, native Calendar list/Record controls, in-app prompts, and opt-in OS notifications are implemented. Refresh reacts to calendar changes, wake, foregrounding and time-zone changes. The EventKit path uses accounts already configured in Apple Calendar, including Google. A separate direct Google OAuth/API path is now implemented, with real-account acceptance pending. No personal calendar read, permission grant, or OS notification delivery was exercised by the audit. Native integration acceptance remains pending.
- [~] **iOS application:** `Apps/project.yml`, generated Xcode project, native iPhone/iPad app and shared Core/Speech/Calendar/UI dependencies build successfully for the simulator. An isolated iPhone 17 Pro/iOS 27 simulator launched the empty library and remained alive; no permissions, calendar connection, model setup, or microphone recording were exercised there. Live Activity/widget, App Group configuration and physical-device background recording remain incomplete.
- [~] **Summaries/library:** extractive notes and explicit Apple on-device generation exist, with bounded evidence/citations and editable Markdown. Mac title/transcript search exists. Long-meeting quality/performance, full hierarchical synthesis, edited revision history, retention and finalized export history remain incomplete.
- [~] **Mac packaging:** packaging/signing script and entitlements exist. Usage descriptions for microphone, Speech and full calendar access are supplied; CLI embeds its own Speech/calendar descriptions. System-audio permission no longer claims success from device presence. A release app was rebuilt, SwiftPM resources embedded, ad-hoc signed and verified with `codesign --verify --deep --strict`. Relocated resource lookup also passed. The local-test app/ZIP are under `build/repair-2026-10-14/`. No notarization/stapling, Gatekeeper acceptance, or clean install/upgrade/uninstall on another Mac was performed.
- [!] Production signing/notarization credentials, TestFlight provisioning, and a physical iPhone are still needed after the missing implementation is completed.

## Verification log

2026-10-15: Reproduced and repaired the missing diarization-label handoff into transcripts, confirmed-name propagation, and legacy internal-ID display. Twenty focused tests passed; integrated Swift runners report 228 tests with five expected opt-in test skips and the opt-in Prism contract suite skipped, zero failures. iOS Simulator build 13 succeeded. Summary citation retry remains strict and bounded; an actual on-device fictional garden fixture yielded three useful cited points. Intro-only speech now reports insufficient conversation. Native microphone metering was verified changing from roughly 20% to 56–58% during playback; the user also spoke, so that mixed capture remains local and was neither exported nor enrolled. Build 13 native design/install verification is in progress; see audit report 16 for evidence and remaining limits.

2026-10-14: Four new outbox regression tests first failed with eight assertion failures, reproducing dropped transcript corrections, wrong destination deduplication, invented confirmed identities, and premature sync success. All four pass after the repairs; 11 outbox tests pass. Local-only Speech request tests and injected AppState capture failure tests were added before their APIs were implemented. Tests use temporary databases and injected recorder/HTTP implementations; this audit did not capture personal audio, modify accounts, or write to a personal vault.

Initial verification: `CLANG_MODULE_CACHE_PATH=/tmp/minutes-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/minutes-swift-cache swift test --disable-sandbox --package-path MinutesKit` completed successfully: 60 tests across 19 suites, including all 8 new regression tests. The build completed successfully; SwiftPM reported only inaccessible user-cache warnings. `git diff --check` passed. No device or external integration acceptance is implied by passing unit tests.

2026-10-14 durability follow-up: Four SQLite failure tests first failed with seven assertions; five outbox recovery/concurrency tests first failed with seven assertions. After repairs, all targeted tests passed (25 tests), including injected disk failures and blocked-storage startup. The full durability follow-up passed 72 tests across 22 suites. The final combined run is recorded below.

2026-10-14 Calendar follow-up: Added six scope/mapping/binding tests and one injected app calendar flow test before implementation. Test fixtures cover half-open event intervals, cancelled/all-day exclusion, recurring occurrence IDs, conservative email mapping, prompt suppression, scoped attendees, persistence, rebinding and explicit connect-before-fetch. No personal calendar, OS notification request, model setup/download or microphone capture is invoked by these calendar tests. Apple Speech requests authorization at first actual use; untimed text imports never invoke recognition, and the old fabricated plain-text timing fallback is rejected.

## Final verification (2026-10-14)

- **Swift suite:** 103 discovered tests, **102 passed and one opt-in model test skipped**, zero failures; `/tmp/minutes-final-all-tests.log`. This includes Calendar mapping/binding/app flow, capture and disk failures, durable audio imports, atomic persistence, outbox concurrency/recovery, provenance safety, grounded summaries, Markdown safety and mocked HTTP failure paths.
- **Real trained model smoke:** explicit setup in `/private/tmp/minutes-trained-model-smoke`, public SDK fixture `01-validation-request-21.4s.wav`, actual trained segmentation/256-dimensional embeddings. Setup-enabled run passed in 8.449 seconds; repeated setup-disabled run passed in 0.361 seconds. No Apple Speech ASR, personal microphone, known-person enrollment, WER/DER or recognition calibration was involved. Logs: `/tmp/minutes-real-model-smoke.log`, `/tmp/minutes-offline-model-smoke.log`.
- **Native iOS:** `xcodebuild -project Apps/Minutes.xcodeproj -scheme MinutesiOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/minutes-ios-build CODE_SIGNING_ALLOWED=NO build` succeeded. Empty-library launch was checked in a new isolated simulator, then only that simulator was shut down/deleted. No physical-device acceptance is implied.
- **Mac package:** release build, embedded `FluidAudio_FluidAudio.bundle`, static SDK dependency inspection, inside-out ad-hoc signatures, strict verification and relocated resource lookup passed. Artifact: `build/repair-2026-10-14/Minutes-1.0.0-local-test.zip` (SHA-256 `74c5ac22c20edcf1b9c323d86eeda52a70860ec1a1b7ae8d154ae97ef457e53f`). It is local-test-only and unnotarized. Sandbox blocked Xcode dsymutil initially; the same build completed with approved build-only escalation, without launching the Mac app.
- **CLI acceptance:** corrupt audio rejection, untimed transcript import, unsupported export rejection before adapter invocation, and Markdown output under a temporary directory passed. No personal database or vault was written.
- **Import repair:** CLI/app share validated, uniquely copied managed audio. Missing-model or other processing failures preserve the saved recording; `processCurrentMeeting()` supports retry. Text import has unknown timing/speakers and no synthetic embeddings; UI labels it `Untimed`. Four shared import tests and two injected app import flow tests pass.
- **Additional repair:** Markdown uses stable meeting identity to avoid same-title collisions, preserves personal notes and escapes YAML. Legacy export rejects unsafe origins/redirects and reports HTTP errors instead of falsely succeeding. Restricted Prism authorization/live server acceptance remains unconnected. Default summaries quote grounded source text for review; no canned architecture overview or invented commitments.

Durable verification logs and the simulator screenshot are in `../audit-2026-10-14/repair-evidence/`. No commits, real calendar access, personal audio capture, personal vault writes, production signing or publishing occurred.


## Recording and Google repair follow-up (2026-10-14)

- [x] Block capture before meeting creation when installed speaker models are missing; explicit setup checks Speech and microphone permissions.
- [x] Replace Mac/iPhone recording modal with inline document workspace, large library Record footer, source selection and actual microphone level history; improve control spacing/accessibility.
- [x] Move first Speech consent out of batch processing, reject unsafe direct-child first-consent launches with a recoverable error, and embed/verify matching app privacy metadata. Native generated-speech import/transcription/diarization passed after owner system approval (one utterance/cluster, app remained running). This does not verify hardware microphone or system-audio capture.
- [x] Restore stored Prism grants on startup, make the initial Keychain lookup noninteractive and allow explicit Verify; cancel sign-in without late reconnection.
- [x] Configure Google project/native clients with owner-approved policy and scope setup; store registration in Keychain and wire public native callback metadata.
- [x] Reproduce/fix desktop OAuth callback closing a delayed browser request because accepted Darwin sockets inherited O_NONBLOCK. Synthetic delayed-browser regression passes.
- [x] Accept real Google native authorization, token exchange, Keychain token save and seven-day events API readback in the final build.
- [ ] Real expired-token refresh and restart/reconnect acceptance remain pending (synthetic coverage passes).

Verification: final synthetic suite 165 discovered, 162 passed, three opt-in skips, zero failures (`../audit-2026-10-14/recording-repair-evidence/swift-registration-final.log`). Mac release package and strict ad-hoc signature/privacy metadata verification passed. Current artifact: `build/recording-google-final-2026-10-14/Minutes.app`. The final iOS simulator rebuild passed after shared registration/Keychain changes; public OAuth/callback metadata was validated earlier. No notarization, App Store release, real-time ASR, speaker accuracy benchmark, two-machine StudioLink acceptance or SaaS parity is claimed. See `../audit-2026-10-14/13-RECORDING-AND-GOOGLE.md`.

2026-10-14 Google acceptance follow-up: native browser callback now succeeds. Google token endpoint diagnostics confirmed this desktop client requires `client_secret`; registration now stays in Keychain and is submitted only on desktop token exchange/refresh. New synthetic tests cover both requests and safe setup error messages. Final native retry passed: owner sign-in completed, tokens were exchanged/saved and the real seven-day events request succeeded. Screenshot: `google-native-connected.png`.

2026-10-14 final native acceptance: final package passed recording readiness, automatically restored the Minutes Staging Prism grant after relaunch, and exported the generated-speech meeting. Mac mini readback confirmed a committed revision-1 receipt and both actual vault notes, including the recognized transcript and source linkage. Evidence: `../audit-2026-10-14/recording-repair-evidence/prism-transcribed-export-readback.json`. This is synthetic imported speech, not hardware capture acceptance.

- 2026-10-16: Build 32 installed on Mac/iPhone with saved-audio/import automatic completion, protected existing summaries/titles, direct People voice enrollment, compact header/search, floating transparent Record overlay, event detail cleanup and native-verified folder drag (manual membership persisted, test restored). Full Swift model-free suite passed. Summary failure reproduced on fictional normal speech: model-generated question schema invented uncertainty and failed grounding. Build 33 source replaces that path with compact/detailed claims plus cited actual unknown-source excerpts; all 35 local summary tests with real Apple inference passed, with 7 final provenance tests. Real 20.55-second English microphone clip remains unrecognized (including amplified copy) while generated speech succeeds; original preserved, playback confirmation requested. See parent audit report 22; no claim of transcription reliability or pixel-perfect Notes parity.


2026-10-16 build 36 native follow-through: signed, Apple-notarized, stapled and Gatekeeper-accepted Mac build installed at the stable path; iPhone 36 installed. Two consecutive microphone captures passed on build 35. Trained-profile explicit enrollment/persist/reopen/automatic-reuse acceptance passed with two generated voices and a wrong-person abstention control. Combined source mixing lost a substantial speech region despite a clean device original, so build 36 now recognizes validated aligned originals independently with source-qualified identities. Native short device capture matched 42/46 reference tokens and generated its AI summary automatically. The historical muffled user clip remains unrecovered. A longer combined test was stopped when the owner reported being with a group; it did not pass acceptance. No more audible playback or microphone tests should run without renewed readiness.

2026-10-16 build 37 follow-up: owner requested system audio without speakers/microphone. Added explicit Mac audio only choice, `includeMicrophone: false` forwarding, source-aware consent and microphone-off UI. Regression first failed for the missing mode/API and then passed alongside recording readiness/source processing tests. Shared iOS UI compilation and full model-free suite pass; Mac 37 is signed, Apple-notarized, stapled, Gatekeeper-accepted and installed. A silent native short capture passed with system-only metadata, zero microphone files, transcript and automatic AI summary. A second short capture routed only to the installed BlackHole virtual output also passed without changing system output. Full long virtual-only acceptance passed: 362.78-second native system-only capture, zero microphone files/capture issues, all 18 generated turns covered, 6.30% raw normalized WER, dominant speaker correct for 18/18 turns under anonymous label mapping; three clusters for two voices (minor over-segmentation). Automatic completion saved an actual on-device AI draft. Generated playback/capture stopped. See `audit/long-virtual-system-capture-build37.json`; no real-human/overlap or original muffled-clip recovery claim. Existing CLI `capture-system --system-only` remains the underlying capability.


### 2026-10-16 — Integrated voice/calendar acceptance and build39
- [x] Real Fluid diarization + app processing + calendar binding + explicit voice enrollment + reopen + later automatic naming acceptance passed with generated voices/isolated DBs (1test,4.267sec). Deterministic timed ASR injection is explicit; this is not a speech-recognition accuracy test.
- [x] Repeated enrollment, accepted/tentative/unknown RSVP, declined exclusion, calendar-alone/wrong-profile abstention, explicit confirmation/unknown preservation, forgetting and enrollment-source deletion controls passed. Three acoustic clusters for two voices remain; no wrong known names in this fixture, small anonymous portion.
- [x] Meeting-review enrollment now calls shared VoiceEnrollment.remember (stale evidence validation/deduplication); People explains device-local profiles and automatic strong-match naming.
- [x] Build39 installed Mac+iPhone; Mac Developer ID notarization/staple/Gatekeeper passed. Native People screen inspected silently, including legacy-profile ineligibility. Preserve older profiles; current-model enrollment requires a new confirmed >=20sec usable sample.
- [ ] Real-human/noisy/overlapping/hardware-change recognition acceptance, native human confirmation of a new compatible voice, and cross-device profile sync remain unverified/unimplemented. No new recording or playback occurred.
- Evidence: `audit/identity-calendar-review-2026-10-16.md`, `audit/minutes-integrated-trained-identity-current.log`.


### 2026-10-17 — Preview40 speaker UX, route recovery and roadmap
- [x] Source-aware voice samples, visible play/pause/progress/disabled states, iOS explicit playback session; native iPhone confirmation now uses fresh persisted evidence and idempotent shared voice enrollment.
- [x] Built-in iPhone microphone preference, bounded/coalesced route graph recovery, retired callback generations and adaptive native converter preserve the existing PCM file. Nonfatal notices explain possible gaps.
- [x] Full model-free suite324tests passed; installed-model integrated workflow1test passed (4.111sec), with real diarization/matching/persistence and deterministic timed ASR fixtures. iOS target compilation passed.
- [x] Research-only roadmaps: optional server meeting capture, live captions/notch and encrypted opt-in voiceprint sync, with official eligibility/platform gates.
- [ ] Physical AirPods switch and audible sample validation; human multi-voice calibration; unrelated cleanMac install; Google registration provisioning for freshMacs; iOS public TestFlight/App Store delivery.
- Release report: docs/release/2026-10-17-preview.md. Public installers/private source explicitly authorized; Minutes preview Google limitation accepted.

- 2026-10-17 release completed: source implementation `50c89cb`/tag `minutes-v1.0.0-preview.40` pushed to private GitHub. Public installers in downloads repository; anonymous fetch/SHA/signature/notarization validation passed. Mac+iPhone40 installed; no capture/playback. See release report for exact hashes and limits.

### 2026-10-17 — Find within a transcript
- [x] Shared local occurrence matching, Unicode-safe highlight offsets, speaker-name matching and previous/next wrap navigation; callable as `minutes-cli find-transcript`.
- [x] Shared Mac/iPhone transcript find controls, result highlights and counts, contextual full transcript, clear/no-match states; note-level Find action. Mac Cmd-F opens meeting find; library Cmd-Option-F remains separate.
- Validation and distribution evidence recorded after build checks below. Future-feature index: `docs/research/FUTURE_FEATURES.md`; server capture and live captions remain research-only.
- Validation: 334 model-free tests passed in the current working tree; final iOS Simulator-target build passed. CLI synthetic transcript returned three occurrences. Native Mac inspection verified highlighted matches, accessible 1-of-3/3-of-3 count, keyboard next navigation and scrolling to a distant paragraph. The delayed-focus fix compiles on both platforms and was subsequently verified in the native Mac preview: Cmd-F focused the field, `cafe` matched `café`, and Cmd-G scrolled to the final `budget` occurrence. No audio capture/playback or personal library changes. This search change is not in submitted TestFlight build41.

2026-10-17: Corrected the Mac meeting-list header overlapping the share/search toolbar. The content column had opted out of the title-bar safe area; removing that override reserves space for the header. Native synthetic-library checks verified populated and empty-folder headers below the toolbar, including an expanded search field. Debug and signed release builds passed. Mac build42 passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment; archive: `build/HeaderFix42/Minutes-1.0.0-notarized.zip`. Replacement of `~/Applications/Minutes.app` is blocked by macOS with Operation not permitted; the installed copy remains build41 until App Management permission or manual replacement. Google Calendar verification was submitted with the owner's video; Verification Center reports data access under review, not approved. Seventeen Google OAuth regression tests passed. All capture and validation remained silent.

2026-10-17: App Management permission enabled by owner. The previous blocked overlay copy had partially modified the installed bundle; replaced the entire bundle with notarized build42, preserving that partial copy under ignored build/HeaderFix42/Partial-install-before-repair.app. Installed ~/Applications/Minutes.app now reports42 and passes strict deep codesign verification, stapler validation and Gatekeeper (Notarized Developer ID). Reopened the normal library and visually confirmed the meeting-list title/count sit below the glass toolbar. No recording or playback. Previous source commits are synchronized with origin/main.

### 2026-10-17 — Build43 TestFlight and navigation refinement
- [x] Added transcript search to uploaded iOS43; simplified folder toolbar, swipe/context deletion, direct import, meeting view/share controls and recording regeneration placement.
- [x] Mac build, iOS archive/export, simulator build,334 model-free tests and native simulator transcript-find/deletion-confirmation checks passed silently. See docs/release/2026-10-17-build43.md.
- [x] Apple processed43; test instructions saved, internal group assigned. Public invitation still blocked pending build41 Beta App Review; Apple only allows one submitted build per version at a time.
- [ ] Attach43 to Minutes Public Beta after Apple's current review completes; physical TestFlight install not yet verified.
- [x] Deferred bot roadmap; clarified native Mac Liquid Glass/scroll-history design and iPhone ActivityKit text versus full scrolling constraints. Future captions remain unimplemented.

### 2026-10-17 — Build44 individual meeting deletion
- [x] iPhone swipe/context Delete and Mac context Delete move meetings into recoverable Recently Deleted; Settings restores the original meeting and folder. Active work is protected; audio/transcripts retained.
- [x] 336 model-free tests passed, followed by six focused folder tests including a new app-selection regression. Synthetic CLI and native iPhone simulator delete/restore passed; simulator original database restored.
- [x] iOS44 archive/export/upload succeeded. Mac44 signed/notarized/stapled, installed and verified with strict codesign/Gatekeeper and native UI inspection. No capture/playback.
- [ ] External TestFlight remains gated on Apple's build41 review;44 supersedes43 for the next public beta update. See docs/release/2026-10-17-build43.md for both builds.

2026-10-17: Apple processed build44 (c922a7d8-2af7-44ca-b15e-696aa50857ea), assigned Minutes Internal and saved What to Test. Build41 remains Waiting for Review; Apple blocks a second external review submission for version1.0.0 until approval. Evidence: build/Release44/TestFlight44-saved.png. Physical TestFlight installation of44 has not been verified.

### 2026-10-17 — Mac native reverse-teleprompter preview (build45)
- [x] Optional camera-adjacent NSPanel, native Liquid Glass, compact/expanded modes, scrollable bounded history, pause-on-scroll/Live, display selection and explicit keyboard focus.
- [x] Local-only streaming Apple Speech preview receives bounded copies after durable audio writes. Microphone/system integration is implemented; voice identity remains separate. CLI text/file fixtures never open audio devices.
- [x]342 model-free tests, native synthetic-text scroll/collapse checks, actual silent file partial recognition, iOS simulator compatibility build and Mac Developer ID/notarization passed. See docs/release/2026-10-17-mac-captions.md.
- [ ] Live device capture with captions enabled, dual-source recognition, long endurance, cross-display/fullscreen/accessibility matrix and streaming speaker identity require further validation.
- [x] Rechecked Apple after fresh login:41 Waiting for Review;44 ready/internal. Public invitation is not accepting new testers.

2026-10-17 Mac build 46: live caption requests now flush at rollover/Stop. Saved compatible voiceprints can provisionally name single-speaker ten-second caption windows using local trained models, strict acoustic thresholds and no automatic enrollment. Real generated profiles survived reload and named 2/2 independent windows; a 354.65-second fixture produced 18 correct named windows/36 with 18 abstentions. All346 model-free tests and iOS simulator compatibility passed. Signed/notarized/stapled build46 installed. Native long system-capture caption test is pending Mac unlock; no playback/capture started. Current launch uses the isolated `/tmp/minutes-caption46-acceptance` library; quit/reopen normally after acceptance. See `docs/release/2026-10-17-live-voice-captions.md`.

2026-10-17 build46 native follow-up: Mac unlocked;409.02-second system-only capture completed silently via verified BlackHole virtual playback. No microphone files/capture issues. Both remembered fictional voices appeared live; scroll-back/Live and compact/expanded controls passed. Final batch transcript covered18/18 generated turns with correct dominant speaker names,4.81% raw WER; automatic summary saved. Live preview reached turn18 but displayed a recognition-restart notice near the end, then clean completion after Stop; no word-perfect live accuracy claim. Profiles remained2. Test stopped and normal254-meeting library restored. Evidence: `audit/live-system-captions-build46.json`.


## 2026-10-17 caption stability / Mac build48

- [x] Prevent silent input from starting recognition tasks; distinguish quiet endings from failure retries and clear stale reconnect notices on new progress. Retain chronological history and late identity labels.
- [x] 349 model-free tests passed; iOS simulator compatibility build passed; Mac48 signed, notarized and installed with matching binary/signature.
- [~] Personal-profile reuse tested silently against two existing recordings: 0/9 windows confidently named, no other-person matches, no profiles changed. Reliable personal live naming remains open.
- Validation details and native final-build result: `docs/release/2026-10-17-caption-stability.md`.


## 2026-10-17 voice reuse / Mac build49

- [x] New owner-confirmed baseline reused automatically in independent untagged recording after fresh store open: 35.7 seconds named; 4.3-second fragment abstained.
- [x] Installed caption panel after app restart showed three owner labels; zero retries/dropped batches. Live windows: 3 matched, 1 weak, 1 too short. Synthetic other-speaker control: zero false owner matches.
- [x] Replaced silent busy-inference drops with bounded FIFO; refresh profiles for pending work; stable identity IDs; await queued analysis at caption finish.
- [x] 352 tests, iOS compatibility build, signed/notarized Mac49 install verified.
- [~] Robust cross-condition real-human accuracy remains an open acceptance gate; thresholds unchanged, no promise of perfect identification. See `docs/release/2026-10-17-voice-reuse.md`.


## 2026-10-17 provisional speakers / build50

- [x] Session-local anonymous speaker grouping and clickable live naming; invitees and other people separated; explicit session-only scope and no automatic enrollment.
- [x] Saved review separates calendar invitees, other saved people and manual additions.
- [x] 353 tests, iOS simulator compile, signed/notarized installed Mac50. Native silent 60-second fixture: two groups, manual naming carried to a later matching window, zero retries/drops.
- [~] Six-condition held-out owner matrix and matching synthetic-negative matrix completed. Gain changes pass; noise misses both paths and telephone-like audio misses live naming. Zero wrong-person matches in these limited samples. Spectral denoising failed and is not shipped. Broad recognition reliability is NOT established.
- Reports: `docs/release/2026-10-17-speaker-controls.md`, `docs/release/2026-10-17-voice-reuse.md`; repeatable silent CLI runner: `scripts/voice-condition-audit.py`.

## 2026-10-17 long recording recovery / Mac51 and iOS46

- [x] Preserved the important iPhone recording twice before changes; post-update original remains byte-identical.
- [x] Replaced global retry cap with per-gap six-/three-second recovery and internal/trailing coverage checks. Preserve low-confidence recognized words through merger.
- [x] Silent full-file Mac verification: 589 words saved, 152 recovered by retries, no remaining detected-speech gaps or exact duplicate word/timestamp entries.
- [x] 357 tests pass; signed iOS46 installed in place; original audio can be shared from a failed meeting. Mac supports Finder Open With import via existing copy-first pipeline.
- [~] iPhone regeneration verification awaits owner unlocking/starting the saved recording; no claim of word-for-word accuracy. See `docs/release/2026-10-17-long-recording-recovery.md`.

- 2026-10-17 follow-up: iOS47 repairs stale managed audio paths after sandbox relocation on update/restore; original file stays untouched. 358 tests pass, build installed, owner asked to reopen and regenerate (device locked). Mac52 installed with single status text and no redundant Details disclosure.

- 2026-10-17 iOS48: phone47 confirmed 591 saved transcript words; fixed non-converging AI summary reduction and removed automatic extractive substitution. Actual phone-transcript local-model run succeeded (6 bullets / 110 words); 359 tests pass. Installed48; awaiting summary-only verification on phone.

### 2026-10-17 — explicit file export and Prism destinations
- Implemented native Markdown Save As on Mac/iOS, configurable Prism folder, optional successful-AI-summary export and capability-gated server folder support. Queue payloads retain destination and idempotency identity. Silent Swift regression and 23 Prism integration tests pass; isolated staging upgraded, phone build 50 built (including preventing idle screen timeout during processing). Mac build 53 installed: native Save As and custom-folder staging receipt verified. iPhone Save As, automatic post-summary delivery and manual-lock lifecycle remain to verify.

### 2026-10-17 — physical lock and automatic Prism acceptance
- iPhone build 52: isolated synthetic audio passed transcription → lock during AI summary → unlock/resume → committed automatic staging export. Locked and unlocked transcripts/timestamps match (270 words, ~104 s). Original personal recording untouched; normal library reopened after test.
- Fixed reproduced stale “waiting for receipt” status after successful automatic delivery. Opt-in live acceptance verifies real local AI generation, receipt, duplicate-free resync, disabled-export gate and extractive-summary exclusion. Earlier apparent crash not reproduced; force-quit/low-memory recovery remains outside this result. See `docs/PROCESSING_LOCK_ACCEPTANCE.md`.

### 2026-10-17 — automatic note names / iOS53, Mac55
- Summary completion now saves a transcript-derived topic title atomically with the summary, including summary retries and recovered recordings. Previously naming only ran on the original recording-completion path. The meeting list, summary heading and automatic Prism payload use the saved name.
- Preserve custom/calendar titles and concurrent title edits. Disambiguate repeated topic names with recording date/time, then an ordinal if needed. Existing timestamp-named notes can use Regenerate Summary without reprocessing audio. Naming uses the existing on-device transcript phrase scorer; insufficient meaningful text leaves the title unchanged.
- Full Swift regression suite passes, including retry naming, duplicate topics and custom-title preservation. Opt-in real Apple-model/staging export acceptance verifies the renamed title and matching Markdown heading. All tests silent and synthetic; original important audio untouched.

### 2026-10-19 — production QA: failed 37-minute call, zoomed window, mic-only suggestions / Mac build 56
- Evidence: the owner's 37:35 call+mic capture finalized cleanly (`capture.json` complete, no issues). Both "crashes" were `exit(0)` quits, not crashes: processing *threw* (status reverted to `recorded`, 0 utterances) after only Apple "no speech" (1110) window responses. No crash reports were written for 2026-10-19.
- [x] Root cause 1, all-or-nothing coverage: any ≥3 s detected-sound gap left after retries discarded the whole meeting, and one weak source discarded both. Now `SpeechWindows.acceptsPartialTranscript` saves transcripts with ≤50% uncovered detected sound and surfaces a persistent coverage notice (`PipelineResult.uncoveredSpeechSeconds`, `skippedSources`). A source with too little text is skipped instead of failing the other. Zero words for substantial speech still fails honestly (`TranscriptCoverageError`).
- [x] Batch Speech requests now have a deadline (max(30 s, 3× window)) and cancellation, and retain their recognizer. A timeout is a retryable window-level miss.
- [x] Stop no longer decodes the full recording on the main actor (header read off-main).
- [x] Zoomed window / missing toolbar: the bottom status card used unbounded `fixedSize(vertical:)` text inside a safe-area inset (since 2afdc34), so long messages raised the window's minimum height past the screen. Now capped at 5 lines with a tooltip for the full text.
- [x] Calendar-suggested and manual Mac recordings default to call audio + microphone; the choice persists (`captureMode`). If call-audio permission is missing, the microphone still records, with an explicit notice.
- [x] Live captions: per-source feed budget, reset only the overflowing source, removed per-tick copy-on-write duplication of sample windows, `finish()` always releases recognizers.
- [x] Declared the `app.minutes.meeting-identifiers` exported UTType (launch fault every start).
- [x] Pipeline progress is now logged at info level (counts and timings only, no text).
- [x] 374 model-free tests pass. Signed (Developer ID, not notarized) Mac build 56 at `build/qa56`.
- [x] Real-recognizer run of the cloned 37-minute capture in an isolated library (`MINUTES_LIBRARY_DIRECTORY` via `launchctl setenv`; `open --env` does NOT propagate it): 158 utterances / 4,558 words, call track 3.1 s and mic 3.3 s uncovered.
- [ ] Install build 56 over 55 (requires quitting the running app), then Regenerate the original meeting.
- [ ] Open: one meeting writes ~2.1 GB (`system.caf` is 48 kHz stereo float plus three 433 MB aligned/mixed copies). Consider compact storage after acceptance.

### 2026-10-19 (continued) — owner report after build 56: summary fails, 29 speakers, empty invitee list / Mac build 57
- [x] Summary: reproduced via CLI on the QA clone. All 24 first-pass chunks succeeded, then Apple's model returned `refusal` for one 2 KB reduction chunk and the whole summary was discarded. Declined/undecodable chunks are now chunk-level misses: first-pass gaps are skipped and disclosed (fail if fewer than half succeed), declined reductions carry their validated inputs forward. Reductions use the 1–3 claim schema so they contract (previously 121→61 bullets after 6 passes, then fell back to all 121). Open-question excerpts no longer quote casual "I don't know…" or run-on (>240 char) sentences. Real run: 158 records → converged notes in ~3.5 min.
- [x] Speakers: FluidAudio's streaming clusters gave 24 call + 5 mic clusters (21 under 3.5 s). Post-pass merges substantial clusters at cosine distance ≤0.25 and assigns <5 s fragments to the most similar substantial voice (pyannote `min_cluster_size` approach). Real audio: 3 call + 1 mic speakers. See DECISIONS 2026-10-19.
- [x] Invitees: the 37-minute meeting was started from Record after two short calendar-bound mic attempts, so it had no event. Recording without an event now binds the single invited event in progress (±5 min lead); overlapping events stay unbound. New "Link calendar event" control on unlinked recordings lists overlapping events.
- [x] Pipeline/summary diagnostics logged at info/error with counts and error kinds only.
- [x] 386 model-free tests pass. Signed Mac build 57 at `build/qa57` (not notarized).
- [x] Owner installed 57, linked the 9:33 recording to Product Tactical, regenerated and summarized: confirmed working.
- [x] iOS build 54 (shares AppState and all MinutesKit fixes; adds the Link calendar event control to meeting detail) built, installed on the owner's iPhone and verified as version 54.


### 2026-10-19 (later) — recording storage, generous speakers, structured notes / Mac 58, iOS 55
- [x] Storage: transcribed recordings compact automatically to mono AAC (37-minute call: 2.1 GB → ~41 MB, <10 s); originals removed only after each encoded file verifies; Regenerate and playback read the AAC layout. Settings → Storage on Mac and iOS shows usage and offers Compress, delete audio of Recently Deleted meetings, delete audio of transcribed meetings older than N days, and per-meeting deletion. `minutes-cli audio usage|compact|delete`. Only managed library files are touched.
- [x] Speakers: short (2–5 s) clusters unlike every main voice stay separate; reference call now 5 call + 2 mic speakers.
- [x] Notes: overview, cited decisions and action items, and timed discussion sections for multi-chunk meetings.
- [x] Owner confirmed re-transcription from compressed audio works. Compression is now automatic for every recording (including failed transcriptions) and for existing libraries after launch; interrupted recordings and imported originals are excluded. Mac 59, iOS 56.

### 2026-10-19 (final polish) — sharing-ready UI, Parachute vault sign-in / Mac 60, iOS 57
- [x] iOS swipe actions: the root `.tint(.primary)` made destructive swipe buttons white-on-white; swipe buttons now set red (Delete) and indigo (Move).
- [x] macOS swipes: the meeting list was a lazy stack, which has no swipe actions; it is now a `List` with Delete and Move swipe actions.
- [x] Moments: mark them live while recording (large button, ⌘B, menu bar); they appear as chips during recording, pins on the waveform scrubber, and a Moments column beside the transcript with what was said at that time. `minutes-cli bookmarks list|add|rename|delete`.
- [x] Toggles: `MinutesToggleStyle` (whole row taps; the trailing orb fills yellow with a check) replaces switches on Mac and iOS.
- [x] People: full meeting history (no 100 cap with `limit: .max`), searchable; `minutes-cli person-meetings --all`.
- [x] Meeting page: waveform player (scrub, pins, mark, regenerate) → summary with real bullets and clickable timecodes (citations no longer show `[T0006]`) → transcript (inline search, open by default when wide) beside Moments (stacked when narrow) → your notes last.
- [x] Toolbar: circular share button (system share of a Markdown file), circular ⋯ menu for Export (Markdown, Parachute vault), Search Transcript, Regenerate, Move, Delete; wider always-visible search field. Summary ⋯ menu has Search Transcript.
- [x] iOS: Record is a large clear-glass circle; summary edit/menu, player and transcript controls are 44 pt.
- [x] Mac icon: the bundle now ships a compiled `Assets.car` with `CFBundleIconName` (macOS 26 surfaces such as minimized-window badges); needs owner visual confirmation.
- [x] Parachute: direct OAuth sign-in to the person's own hub and vault (see DECISIONS); no hard-coded origin.
- [x] 406 model-free tests pass; iOS simulator build passes.
- [ ] Owner: sign in to agent.omniharmonic.com from Settings → Connections and export one meeting; confirm the minimized-window icon.
- [x] Notarization: Keychain profile `minutes-notary` (App Store Connect team API key 4T2ULU48SH in ~/.private_keys; the old key HZ68R975P9 is rejected). Mac build 65 notarized, stapled and Gatekeeper-accepted ("Notarized Developer ID") at `build/release65/Minutes-1.0.0-notarized.zip`, with iCloud sync. Not yet published.
- [x] Owner follow-ups: iOS record button now Voice Memos proportions (48 pt core in a 60 pt ring); the meeting list uses plain rows so swipes slide without the inset card's corner switching mid-gesture. Mac 60 installed.
- [x] iCloud sync (MinutesSync, CKSyncEngine): meetings with transcripts, summaries, notes, moments, folders, people and optional recordings; three-way merge; voice embeddings stay local. `minutes-cli sync status|pending|payload|reset`. 413 tests pass. Mac 61, iOS 58.
- [x] iCloud provisioning done without the portal (Xcode-managed container/capability, Developer ID profile via Xcode export), schema imported with cktool and deployed to Production. Live: Mac library uploaded (283 records) and an isolated library downloaded an identical copy with no voice embeddings. Fixed a crash found live (an unlocked store read raced the main thread). Mac 63 (sync on), iOS 59.
- [ ] Owner: turn on Settings → Sync on the iPhone and confirm meetings appear.

### 2026-10-20 — public release with updates / Mac 66
- [x] Sparkle 2.10.0 updater: EdDSA key in the login Keychain (account `ai.nosaas.minutes`), public key and feed in Info.plist; Sparkle asks before automatic checks (opt-in, local-first); "Check for Updates…" in the app menu. build-app.sh embeds and signs Sparkle's helpers.
- [x] Public repo https://github.com/omniharmonic/minutes-releases (README, appcast.xml, releases). `scripts/publish-release.sh <build-dir> "<notes>"` signs, releases and updates the feed.
- [x] v1.0.0-66 published: notarized, Gatekeeper-accepted after download, Sparkle signature verified against the live feed. Website links point to the new repo.

2026-10-20: iOS 1.0.0 (61) exported with App Store signing (new distribution profile includes iCloud, Production CloudKit, get-task-allow false; only the iOS Google client ID is bundled) and uploaded to App Store Connect, delivery 6211d3a1-96e6-46f4-9895-7eae684e71c3. Processing and the public TestFlight review are still pending.

2026-10-20: Distribution check for friends. Mac release 70 downloaded from the public link: notarized, Gatekeeper-accepted, Google desktop registration present. TestFlight: build 41 is approved, and the public link https://testflight.apple.com/join/jWJ68SJV (100-tester cap) serves 41. Build 61 is processed, with What to Test saved, but the API key can't add it to the public group or submit it for review (403), so the owner does both in App Store Connect. Site About page now links the iPhone beta and states macOS 15+; deployed as release 20261020-testflight. The Google demo steps were rewritten for owner-recorded Mac and iPhone takes using a separate "Minutes Demo" calendar.

2026-10-20: iOS 61 approved by Beta App Review and in the Minutes Public Beta group (state IN_BETA_TESTING); public link https://testflight.apple.com/join/jWJ68SJV is live. TestFlight builds expire 90 days after upload (~2027-01-18).

2026-10-21: Fixed iPhone long-recording processing, diagnosed from the owner's phone data. The meeting was 2h10m and captured cleanly. The transcript was saved (641 segments) but the summary was missing. Diarization reached 4 clusters. Background continued-processing task (iOS 26+), progress reporting, busy-model retry, summaries that resume automatically, and chunk sizes from the context size. 431 model-free tests pass and the iOS device build succeeds. Not yet verified on the phone.

2026-10-21: iOS recording Live Activity (`MinutesLiveActivity` extension: timer, waveform, title, optional caption line, Stop and Moment intents; throttled to ~1 update/s) and optional on-device live captions on iPhone (Settings → Live captions; scrolling view in the recording screen). Pure logic in the new `MinutesActivity` module with Swift Testing coverage. `swift test` and the iOS Simulator build pass; physical-device Live Activity and locked-phone caption behaviour are not yet validated.

2026-10-21: Live caption speaker grouping recalibrated. On the owner's 2h10m three-speaker recording, minutes-cli caption-voice-file produced 64 anonymous groups before and 3 after. Version bumped to Mac 71 / iOS 62.
