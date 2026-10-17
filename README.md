# Minutes

Minutes is a native Swift meeting recorder and local processing application, with a shared Swift package and CLI. It is under development. See [STATUS.md](STATUS.md) for implementation evidence and release blockers; unit tests and compilation do not establish real-device reliability or speaker-identification accuracy.

Current processing uses **Apple Speech with mandatory on-device recognition** and trained **FluidAudio 0.17.7 diarization/WeSpeaker models**. It does not use Parakeet ASR. Models must be installed explicitly; unsupported local recognition and missing models fail with an actionable error. Configured exports can send meeting content to their destination.

## Download

Signed Mac previews and setup guides are published in [Minutes & StudioLink Downloads](https://github.com/omniharmonic/minutes-studiolink-downloads). Sources stay private. iPhone development installs are paired-device tests, not public App Store/TestFlight distribution. See [release setup](docs/RELEASE_SETUP.md) for known limits.

## Find within a transcript

Open a meeting and choose **Find in transcript** below its Transcript disclosure (or use the iPhone meeting’s More menu). On Mac, **Command-F** opens this meeting’s transcript search; **Option-Command-F** searches the library. Search is local, case/accent insensitive and literal. Matches in words and speaker names are highlighted in context, with a count and previous/next controls (Command-G / Shift-Command-G on Mac). Finding a match scrolls the text without starting playback. Transcript editing remains available from each segment’s pencil.

CLI: `minutes-cli find-transcript <meeting-id> <query> [--data-dir <path>]` emits matching segment IDs/fields/offsets, without transcript contents.

Future research is indexed in [future features](docs/research/FUTURE_FEATURES.md): optional server meeting capture, local live captions/camera-adjacent UI, and separately consented voiceprint sync. These remain research plans, not shipped capabilities.

## Build and test

Requires macOS 15+, Xcode 26 or newer (Swift 6 language mode), and Apple Silicon for the current local speech stack.

```sh
swift build --package-path MinutesKit
swift test --package-path MinutesKit
swift run --package-path MinutesKit minutes-cli --help
```

Tests use temporary databases and injected recorder/network/inference implementations. They do not require personal audio, a personal calendar, model weights, or a live vault. An explicit trained-model smoke and isolated iOS simulator library launch were also verified; see STATUS for their limits. Physical-device acceptance remains separate.

## Models

```sh
minutes-cli models status
minutes-cli models setup
```

`setup` explicitly downloads and verifies the trained segmentation and speaker embedding models. Normal processing never silently downloads them. The app offers the same action under **Settings → On-device speech**. Apple Speech also requires Speech permission and a supported on-device language/device. Model setup does not demonstrate transcription quality, diarization accuracy, or a calibrated identity match.

## Import and process

```sh
minutes-cli import /path/to/recording.wav --title "Planning" --data-dir /path/to/local-data
minutes-cli process <meeting-id> --data-dir /path/to/local-data
minutes-cli show <meeting-id> --data-dir /path/to/local-data
```

Audio import validates the file and persists a separate managed copy. Deleting the source does not delete that copy. The app's import flow also runs the real pipeline; if processing fails or models are missing, the imported recording remains saved and can be processed again after setup.

```sh
minutes-cli import-transcript /path/to/transcript.txt --data-dir /path/to/local-data
```

Plain-text imports have unknown speakers and no verified audio timestamps. They do not create embeddings or fabricated speech durations. Plain text is not accepted as a timed ASR fallback; use `import-transcript` instead of the old `process --transcript` option.

## Calendar

Calendar supports read-only **Apple Calendar/EventKit** and **direct Google OAuth**. Google uses system-browser PKCE and Keychain credentials, refresh/revocation and paginated event reads. Owner Mac/iPhone Google acceptance has passed. New Mac installations still need intentional Desktop registration provisioning and Google public-audience verification; see [Google setup](docs/GOOGLE_CALENDAR_SETUP.md). Choose one provider for prompts to avoid duplicate reminders.

In the app, open **Calendar → Connect Apple Calendar** and grant full calendar access. The list shows timed, non-cancelled events for seven days. **Record this meeting** attaches the selected occurrence's title, conference URL and invitees. Calendar invitees are context, not confirmed speakers; binding an event does not enroll voices. Meeting notifications are a separate opt-in action, and recording requires an explicit action.

```sh
minutes-cli events --today --request-access
minutes-cli events --days 7 --json
minutes-cli bind-event <meeting-id> '<event-occurrence-id>' --today --data-dir /path/to/local-data
```

Choose an occurrence ID printed by `events`. Minutes never creates or edits calendar events. The CLI embeds calendar and Speech usage descriptions; macOS may associate its permissions with the terminal used to launch it. Automated tests use synthetic event snapshots and never read a personal calendar.

## Speaker review

```sh
minutes-cli assign <meeting-id> '<cluster>=<person-or-email>' --data-dir /path/to/local-data
minutes-cli assign <meeting-id> '<cluster>=<person-or-email>' --learn --data-dir /path/to/local-data
```

Assignment changes the meeting's speaker label. Learning requires explicit `--learn` consent and compatible trained-model provenance; legacy spectral/demo vectors are excluded. In the app, learning defaults off and applies only to the selected confirmed cluster. Compatible saved voices automatically prefill strong matches (.88 similarity and .12 margin); matches remain reviewable. Calendar invitees never identify a voice on their own. People → Connect voice offers source-aware sample playback and explicit enrollment. Profiles stay on the enrolling device; older model profiles need new samples. Cross-session generated-voice reuse and reopen tests pass; broad human/noise/overlap accuracy remains uncalibrated.

## Summaries and exports

```sh
minutes-cli summarize <meeting-id> --data-dir /path/to/local-data
minutes-cli export <meeting-id> --target markdown --output-dir /path/to/notes --data-dir /path/to/local-data
```

The default summary is extractive text for review. An optional **Apple on-device Foundation Models** provider is available on eligible macOS/iOS 26+ devices with Apple Intelligence enabled. General, 1:1, standup and interview formats use bounded, timestamped evidence; user notes remain separate untimed context. Generated claims require references to supplied evidence and still need human review. Long-meeting quality/performance remain unbenchmarked.

Native Parachute delivery now uses a dedicated **Minutes → Prism** browser sign-in and durable outbox. It requires verified restricted capabilities before sending and a committed receipt before reporting success. The restricted client, selected-vault grants and idempotent import/receipt endpoints are implemented against stable Prism `288ce029` and passed real Swift-to-local-server HTTP acceptance. An isolated staging service is deployed at `minutes.omniharmonic.com`; native account consent, restricted staging-vault exports, receipt readback and revisions passed. Production release and broader reliability acceptance remain open. See [Prism setup](docs/PRISM_CONNECTION_SETUP.md). The legacy macOS CLI adapter remains an explicitly separate CLI option. Ordinary exports exclude biometric vectors.

## Packaging and remaining work

```sh
./scripts/build-app.sh
# Quit Minutes before replacing its installed bundle.
./scripts/install-local-app.sh "$PWD/build/Minutes.app"
```

The build script embeds SwiftPM resource bundles and verifies signatures. The installer uses `~/Applications/Minutes.app`, backs up upgrades and unregisters workspace previews so permission restarts reopen the installed app. Ad-hoc rebuilds change the code requirement; an enabled screen permission can still refer to the previous build. Diagnose that mismatch before requesting any owner-authorized Minutes-only permission reset. Never reset unrelated apps or privacy services. Without `DEVELOPER_ID_APPLICATION`, it creates an **ad-hoc local-test package**, not a notarized distributable. With a Developer ID and `NOTARYTOOL_PROFILE`, the script also submits, checks acceptance, staples, validates and assesses Gatekeeper. Developer ID signing/notarization and local installation pass; an unrelated clean-device installation remains unverified; see [release setup](docs/RELEASE_SETUP.md). The native iOS simulator target in `Apps/project.yml` builds, and its empty library was launched in an isolated simulator. See `STATUS.md` for evidence and physical-device limitations.

The Mac recorder now offers **microphone** or **Mac call audio + microphone**. Call capture preserves original source CAF files plus timing metadata and renders a synchronized 48 kHz processing copy. It requires explicit Microphone and Screen & System Audio Recording permissions; no screen images are saved. See [capture implementation and limits](docs/research/system-audio-capture.md). Live hardware capture, route changes, long sessions, crash recovery, physical iPhone background recording, calibrated speaker identification and full release acceptance remain unverified. No Granola/Meetily feature parity is claimed.

## Native product interface

Minutes follows the system appearance with native navigation/toolbars and Liquid Glass control surfaces on macOS/iOS 26+, with material fallbacks on supported older systems. Notes/transcripts use readable content surfaces. The Mac library searches meeting titles and transcripts; notes and summary Markdown can be edited and exported explicitly. Public connection settings persist separately from Keychain credentials.

An explicit `MINUTES_LIBRARY_DIRECTORY=/path/to/isolated-library` launch uses a separate database, audio directory, export directory and preferences profile for safe previews/testing. It does not use a hidden temporary fallback on storage failure.
