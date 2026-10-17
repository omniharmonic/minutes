# AGENTS.md: working on Minutes

## Before you start
1. Read `docs/PRD.md`, then `docs/ARCHITECTURE.md`, then `docs/IMPLEMENTATION_PLAN.md`, then `docs/research/findings.md`.
2. Pick the first unchecked task in `STATUS.md` whose dependencies are done. Spikes first.
3. When you finish, tick the box and add a dated log line. Update docs/ADRs if reality differs from the plan.

## Conventions
- Swift 6 language mode, strict concurrency. Use `actor`s for services that own state (Pipeline, stores). Mark value types `Sendable`.
- All logic lives in `MinutesKit`. App targets contain only SwiftUI views and view models. **Every feature must be callable from `minutes-cli` first.**
- Modules depend downward only: `Core` ← `Capture/Speech/SpeakerID/Calendar/Summarize/Export/Detect` ← apps. Adapters receive a `MeetingExportBundle` and never touch the DB.
- Persistence: GRDB migrations are append-only (`v1_…`, `v2_…`). Never edit a shipped migration.
- Xcode projects are generated: edit `Apps/project.yml`, run `xcodegen`. Don't hand-edit `.pbxproj`.
- Tests: `swift test` must pass without models or network. Model-dependent tests are gated by `MINUTES_MODELS=1`; live Parachute tests by `MINUTES_LIVE_PARACHUTE=1` (+ `PARACHUTE_TOKEN`).
- Logging: `os.Logger` with subsystem `app.minutes`, a category per module. Never log transcript text or tokens at default level.
- Commits: conventional commits with the task ID, e.g. `feat(speakerid): hungarian matcher [MN-1.7]`.

## Guardrails
- Local-first: no network calls except model downloads, user-configured LLM/export endpoints and calendar. No analytics SDKs.
- Secrets (API keys, OAuth tokens, Parachute JWT) go only in the Keychain.
- Voiceprints are biometric-ish data: provide delete paths, never export them via adapters, and never log vectors.
- Don't write to the user's real Parachute vault in automated tests unless `MINUTES_LIVE_PARACHUTE=1`, and then only under the path prefix `Minutes-Test/`.
- If a spike invalidates an assumption (thresholds, API shape, platform minimums), update ARCHITECTURE + DECISIONS before building on it.

## Owner-approved native Google registration exception (2026-10-17)
The owner explicitly approved distributing the existing Google **Desktop native public-client registration** as an extractable resource in the signed Mac app, then importing it into each user's Keychain. Only build-time injection is allowed: no registration value in source, Info.plist, logs or chat. User Google access/refresh tokens and Apple credentials remain Keychain-only and are never bundled. PKCE/state checks and strict matching to the public desktop client ID remain required. iOS never bundles the desktop registration.
