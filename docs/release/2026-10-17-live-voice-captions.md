# Mac live captions and provisional saved voices — build 46

## Implementation

- Captions retire recognition requests with `endAudio` and a bounded two-second final-result grace period instead of cancelling immediately at rollover. Stop drains queued PCM and allows the same bounded flush. Closing the panel still cancels immediately.
- When saved profiles exist, PCM is split into exact ten-second per-source windows. The installed local segmentation/WeSpeaker models analyze each window off the main actor. One inference runs at a time, with no queued backlog. Ordinary recognition without voice profiles retains 45-second windows.
- Compatible confirmed profiles are read from the local store each time captions begin. No profile is created or updated by live matching. No calendar prior can promote a weak acoustic match.
- A whole caption block receives a provisional name only for one detected speaker, no overlap, at least five seconds of detected speech, consistent segment embeddings, cosine similarity >=0.90, and a competitor margin >=0.12. Stored training must contain >=20 seconds and use the compatible 256-dimensional trained model. Otherwise the source label remains.
- Labels read `Name · likely · source`. These are disposable preview labels, not edits to the final transcript or confirmed speaker assignments. Names may arrive after a ten-second window plus inference time. This is not word-level live diarization.
- `minutes-cli caption-voice-file <path> [--data-dir <path>]` exercises the same model path with counts-only output and no recording/playback. `caption-file` now flushes the last recognition request.

## Validation

Model-free tests cover compatible matching, 48 kHz conversion, mixed/overlapping/short/out-of-range windows, and ineligible profile provenance. The opt-in real-model acceptance creates two fictional profiles, persists/reloads them, and names independent ten-second generated turns correctly (2/2), with existing negative controls passing. It uses no personal profiles, microphone or playback.

The initial 12-second real-model test abstained on both voices: the model produced spurious extra speakers in partial trailing chunks. Exact ten-second windows fixed this without lowering identity thresholds. Short final windows can still abstain safely.

Native system-capture and long-session results will be recorded below after verification. No real-human accuracy or overlapping-speech accuracy claim is made from generated fixtures.

## Results from this pass

- All 346 model-free tests passed. iOS simulator compatibility build passed.
- Real-model acceptance passed with persisted/reloaded generated profiles: 2/2 independent ten-second probe windows named correctly.
- The 354.65-second generated two-voice recording yielded 36 windows: 18 named, all matching ground-truth speaker timing, and 18 abstentions. Every named window contained only its expected voice. No stored profiles changed. This was accelerated file analysis, not a real-time capture/latency test.
- Mac build 46 was Developer ID signed, Apple-notarized, stapled and installed at `~/Applications/Minutes.app`. Installed executable matches the packaged binary; unrestricted codesign verification passes. A sandboxed verification returned a misleading signature failure; verification outside the sandbox confirmed the signature.
- Live native system-capture/long-caption rendering acceptance is **pending**: macOS locked during setup, before any capture or virtual playback began. The user was asked to unlock. No sound or microphone capture occurred during this pass.
- The installed app was launched with `MINUTES_LIBRARY_DIRECTORY=/tmp/minutes-caption46-acceptance`, containing synthetic generated profiles only. The normal library is unchanged. Quit this test launch and reopen normally after acceptance to return to the real library.

Local evidence: `/tmp/minutes-captions46-final-tests.log`, `/tmp/minutes-live-voice-long-test.log`, `/tmp/minutes-long-live-identity.log`, `/tmp/minutes-captions46-ios.log`, `/tmp/minutes-captions46-package.log`. The native system test should use `/tmp/minutes-virtual-play` with the six-minute generated fixture, fail-closed BlackHole output verification, Mac audio only selected, captions visible, and no microphone. It must not be reported as passed based on this file-only acceptance.
