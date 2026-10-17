# Mac native caption panel — implementation preview

## Scope

Optional app-owned AppKit NSPanel immediately below the selected display's camera/menu safe area. SwiftUI uses native Liquid Glass on macOS26+, a material fallback on macOS15 and an opaque accessibility surface for Reduce Transparency. The panel supports compact/expanded modes, display selection and dragging. Opening it does not start recording; closing it stops the preview only.

Captions → Show Live Captions enables the preview for current/subsequent recordings in this app session. Captions → Preview Captions Silently runs synthetic text. Preview Captions from Audio File feeds an existing file at approximately real time without opening microphone or audio output. These previews do not create meetings or modify the library.

## Data path and limits

Committed microphone and ScreenCaptureKit source buffers offer disposable mono copies to a disabled-by-default queue. Copies are bounded to 24 chunks and approximately 2 seconds; oldest preview audio is discarded on overflow. Recognition is independent of durable capture and final batch processing. Apple's Speech request requires on-device recognition and existing authorization; it never requests consent or falls back to cloud recognition. Initial language is en-US.

The preview rotates recognition sessions after 45 seconds and on source format changes. Failures have a 2 second retry delay and stop retrying after five consecutive failures without text. Late callbacks are rejected by session ID/epoch. Preview history retains 200 bounded segments (maximum 4000 characters each), replacing partial text in place. Scroll interaction pauses follow; Live explicitly resumes. The completed transcript remains authoritative. Source labels are Microphone/Mac audio, not claims of speaker identity. Live voiceprint matching is not included.

## Validation

- 342 model-free tests passed, including new history revision/finality/retention and PCM copy/downmix/backpressure tests.
- CLI `caption-fixture` passed, retaining the expected latest three lines. `caption-file` refused missing CLI Speech permission without requesting it; native signed-app recognition validation follows.
- No microphone input, audible playback or route changes used in this pass.

## Remaining acceptance gates

Actual microphone/system capture with preview enabled, simultaneous dual-source recognition, long-session resource/latency and stop-boundary measurements; multiple physical displays; fullscreen/Spaces/Stage Manager coverage; accessibility and screen-sharing visibility. This preview is not an iPhone Live Activity and does not render inside the physical camera cutout.

## Native preview results

Mac build45 is Developer ID signed, notarized and stapled. Native UI checks verified compact/expanded sizing, scroll-back pausing follow, the Live control restoring scroll position to the latest text, and explicit keyboard focus. A generated speech fixture produced real partial transcription in the installed signed app with no microphone or playback. The file ended in a readable completed-preview state; preview wording includes recognition errors and is not the batch transcript. Screenshot: `build/Captions45/silent-file-captions.png` (ignored local evidence). iOS simulator compatibility build passed; no iPhone feature was installed.

Apple status checked after owner renewed sign-in: build41 still Waiting for Review, build44 Ready to Submit/Minutes Internal. Public link still says it is not accepting new testers. No external approval was inferred or submission withdrawn.

A second70second generated fixture completed across recognition sessions with continued partial text. This proves basic rollover continuity, not word-perfect boundaries or an endurance/latency guarantee. Playback remained silent.
