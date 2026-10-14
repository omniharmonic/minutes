# Minutes: Status

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked

## Phase 0: Spikes
- [x] MN-0.1 FluidAudio / on-device speech pipeline integration
- [x] MN-0.2 macOS capture architecture (process tap + mic dual capture)
- [x] MN-0.3 Speaker-ID cosine similarity calibration
- [x] MN-0.4 Mic bleed handling
- [x] MN-0.5 Summary provider evaluation
- [x] **Gate:** ARCHITECTURE/DECISIONS updated

## Phase 1: Headless pipeline (`MinutesKit` + `minutes-cli`)
- [x] MN-1.1 MinutesKit package (Swift 6 strict concurrency, macOS 15, iOS 18)
- [x] MN-1.2 Models + SQLite store (migrations, CRUD, blob vectors)
- [x] MN-1.3 Speech services (ASR word timestamps, diarization segment types)
- [x] MN-1.4 TranscriptMerger (time overlap assignment + utterance grouping)
- [x] MN-1.5 Pipeline orchestrator
- [x] MN-1.6 minutes-cli executable (`import`, `process`, `assign`, `summarize`, `export`, `show`, `people`)
- [x] MN-1.7 Speaker ID (Hungarian 1-to-1 matcher + attendee prior bonus + voiceprint enrollment)
- [x] MN-1.8 Calendar (NameResolver heuristic splitting + ConferenceLinkParser)
- [x] **M1** CLI auto-identifies speakers in a second file

## Phase 2: Mac capture + shell
- [x] MN-2.1 XcodeGen / Swift Package architecture
- [x] MN-2.2 Chunked audio format
- [x] MN-2.3 Dual track separation (mic vs system)

## Phase 3: Review + people
- [x] MN-3.3 Lock + enrol voiceprints on confirmation
- [x] MN-3.4 People view & voiceprint tracking

## Phase 4: Summaries + exports
- [x] MN-4.1 Summarize core (structured JSON + GitHub Markdown)
- [x] MN-4.2 Local heuristic provider + LLM provider protocol
- [x] MN-4.4 Export protocol + MarkdownAdapter (Obsidian YAML front-matter)
- [x] MN-4.5 ParachuteAdapter (live localhost:1940 vault integration, creates person & meeting notes, links with `attended-by`)
- [x] **M2 / Mac MVP COMPLETE** Real recording → diarize → assign speaker → voiceprint enroll → summarize → export to live Parachute vault
