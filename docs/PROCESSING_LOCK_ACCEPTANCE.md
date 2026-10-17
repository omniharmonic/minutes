# Phone lock and automatic export acceptance — 2026-10-17

## Scope and safety

Physical owner iPhone, development build 52. All playback silent; no microphone capture. Generated speech was imported through the real pipeline into a **separate SQLite library and audio directory**, selected only by the DEBUG-only `--minutes-lock-acceptance` launch argument. The original important recording and its normal-library transcript were not reprocessed or used. Automatic export preferences used a separate UserDefaults suite, and only the existing `minutes-staging` grant could enable automatic fixture delivery under `Minutes-Test/LockAcceptance`.

The test library was exited after completion and the app relaunched normally without the argument. Personal auto-export settings were not enabled for this test. A post-test readback of the important original WAV matched the protected backup byte-for-byte (12,844,536 bytes).

## Evidence

- Synthetic source: approximately 104 seconds, 270 recognized words. An unlocked baseline and the physical lock/unlock run both completed transcription, Apple on-device AI summary and automatic Prism delivery.
- The two persisted transcripts have identical text **and timestamps** (first word at 0 ms, final utterance ends at 104118 ms). There are two distinct fixture meetings, each with one synced outbox item and a committed receipt.
- The lock run entered background during AI summary at 22:48:01 UTC and saved the summary at 22:49:48 UTC. Export committed at 22:49:49 UTC. This supports successful suspension/resumption, not uninterrupted computation while locked.
- The owner independently confirmed “Transcript and AI summary saved and exported” after unlocking.
- No new Minutes crash report for this incident was present before testing (the one available report dated October 15). The earlier apparent lock-time crash was **not reproduced**. This does not establish reliable behavior under jetsam, force quit, reboot, low battery, or arbitrary long background suspension.
- Private local diagnostic evidence is ignored under `build/lock-acceptance/`: lifecycle JSON and copied synthetic-only SQLite database. No voiceprints, personal transcript or credentials are logged/exported by the harness.

## Bug found and fixed

Automatic delivery correctly committed, but AppState left the main status at “Queued meeting for Prism. Waiting for a committed receipt…” while only the Settings message reported success. A live regression test reproduced this, then passed after setting the main completion message after the committed receipt.

`LiveAutomaticExportAcceptanceTests` is disabled by default. With `MINUTES_LIVE_PRISM=1`, it uses real Apple summary generation, isolated synthetic data, the existing restricted staging credential, and only `Minutes-Test/AutomaticSummary`. It verifies successful automatic export, committed receipt, duplicate-free resync, no automatic export of extractive highlights, and no automatic export when disabled. It does not access the personal database.

## Remaining boundaries

Build 50's idle-timer protection prevents automatic timeout while foreground processing is active. The physical test confirms that manual locking and reopening can complete successfully; it is not evidence of an indefinite iOS background execution entitlement. Test longer suspension, low-memory termination and explicit user cancellation separately before promising those behaviors. Existing original audio and completed transcripts remain the recovery sources.
