# Minutes

A free, local-first Granola alternative for macOS and iOS. It does on-device Parakeet transcription and speaker diarization, pulls participants from your calendar, lets you drag names onto speakers, remembers voiceprints across meetings, writes local summaries, and exports to Markdown, your Parachute vault, Google Docs and more.

**Status:** planning complete; next up is Phase 0 spikes. See [STATUS.md](STATUS.md).

| Doc | Purpose |
|---|---|
| [docs/PRD.md](docs/PRD.md) | What and why: goals, flows, requirements (MN-FR-xx) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How: modules, data model, pipeline, speaker ID, adapters |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | Order of work, tasks with Definition of Done |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Decision log |
| [AGENTS.md](AGENTS.md) | Rules for coding agents |
| [docs/research/findings.md](docs/research/findings.md) | Verified research (FluidAudio, Meetily, platform APIs, Parachute API) |

**Stack:** Swift 6 · SwiftUI (macOS 15+/iOS 18+) · FluidAudio (CoreML/ANE) · GRDB · EventKit · Apple Foundation Models / MLX / OpenAI-compatible · XcodeGen.
