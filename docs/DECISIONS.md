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
