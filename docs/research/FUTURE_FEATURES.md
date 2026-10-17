# Future Minutes features

Status as of 2026-10-17: research and staged acceptance plans, **not shipped features**. The implementation choices below remain proposals. Existing local recording, review and explicitly confirmed voice enrollment remain the baseline.

## Optional server meeting capture

[Detailed spec and source evidence](meeting-bot-roadmap-2026-10-17.md).

Keep Minutes as the product, with an optional Minutes Server add-on. Prism provides authentication, isolated provider credentials and vault delivery; Omni may schedule bounded jobs. Local recording must continue to work without any server.

The research recommends testing Zoom RTMS eligibility and Google Meet post-meeting transcript import first. It does not establish a universal bot that joins arbitrary calls. The October 17 research found Google's live Media API closed to new preview signups and Zoom's Linux SDK guidance directing AI notetakers to RTMS. Recheck platform rules and the owner's actual account entitlements before implementation. Calendar OAuth alone cannot grant meeting media access.

Next gate: inventory the owner's Zoom plan/Developer Pack and Google Workspace/preview eligibility, choose one supported route, and test start/stop/consent plus one complete import. Then test reconnects, a 60-minute session, retention, tenant isolation and costs. No provider app, server capture worker or bot was deployed for this research.

## Local live captions, remembered speaker names and notch-adjacent UI

[Detailed spec and source evidence](live-captions-and-notch-roadmap-2026-10-17.md).

Implement streaming local transcription first, provisional speaker attribution second, and the floating interface third. Durable recording always has priority; the completed transcript remains authoritative. Live guesses must not silently enroll or update a saved voice.

Start with a timed-file CLI spike using the pinned FluidAudio EOU API. Compare rolling WeSpeaker matching with Sortformer plus a separate WeSpeaker identity step. Existing voice vectors cannot directly prime Sortformer's audio-enrollment API; its four speaker slots require an explicit fallback. Measure latency, wrong-name rate, abstention, memory and thermals rather than treating model marketing numbers as achieved performance.

Mac: a real SwiftUI/AppKit panel below or beside the camera, with a regular-window fallback on non-notch displays. iPhone: in-app continuous captions plus an ActivityKit experiment for status and brief completed text; no promise of arbitrary overlays over other calling apps.

Next gate: bounded streaming queues and flush/reset behavior on generated fixtures, followed by identity evaluation, panel behavior across displays/fullscreen, and a 60-minute device endurance/accessibility test. No live-caption or notch UI has shipped.

## Separate dependency: voice profile sync

[Opt-in voiceprint synchronization research](voiceprint-sync-options-2026-10-17.md) covers cross-device profiles. Profiles are currently device-local. Normal meeting export is not permission to upload biometric vectors; any sync needs separate consent, model compatibility and deletion/revocation behavior.
