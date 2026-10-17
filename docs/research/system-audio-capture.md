# System audio capture implementation — 2026-10-14

Minutes now uses **ScreenCaptureKit on macOS 15+**, rather than the planned Core Audio process tap. A single `SCStream` emits separate `.audio` and `.microphone` buffers in the stream synchronization clock. This uses macOS **Screen & System Audio Recording** permission, plus Microphone permission when selected. It does not meet the earlier narrower Core Audio permission assumption. iOS continues using microphone capture; it cannot capture other apps' audio through this implementation.

The service registers audio outputs only: no screen image output is registered or saved. The display filter provides the system-audio capture scope. `excludesCurrentProcessAudio` excludes Minutes playback. Microphone capture comes from ScreenCaptureKit's dedicated microphone output, not a second AVAudioEngine capture, so Minutes does not deliberately capture the mic twice. Physical speaker bleed remains possible; headphones are recommended. This implementation does not claim echo cancellation or speaker separation between source tracks.

## Explicit setup and CLI

The bundled app or CLI must have a stable macOS privacy identity. The CLI embeds a microphone usage description; the app retains its microphone entitlement and usage description. ScreenCaptureKit permission is requested using `CGRequestScreenCaptureAccess`, never inferred from the presence of an audio device. Only the user's explicit permission action or the CLI `--request-permission` option requests access. Startup/status checks only preflight permission.

```
minutes-cli capture-system --output-dir /path/to/new-capture --seconds 60 --request-permission
minutes-cli capture-system --output-dir /path/to/new-system-only --seconds 60 --system-only
```

The command is an explicit recording action. Ctrl-C stops and finalizes the recording. It does not transcribe, send audio, or install speech models. macOS may require restarting the application after permission changes. An existing output directory is refused to prevent replacing a prior recording.

## Files and synchronization

`system.caf` and optional `microphone.caf` preserve committed samples at each source's native format. `capture.json` records source frame ranges, actual presentation timestamps, sample rates, channels, errors, and completion state. Contiguous segments coalesce; periodic atomic checkpoints preserve timing metadata during capture. A process crash can leave an incomplete final audio packet or metadata tail; this is not a crash-proof archival format.

On stop, queued callbacks drain, source writers close, and a bounded-buffer offline render resamples each source to mono 48 kHz. Source timestamps determine leading silence and gaps; no acoustic offset is guessed. Aligned tracks are retained beside the originals. `mixed.caf` averages selected sources with fixed gain to avoid additive clipping. The returned `processingURL` is nonnil only after successful capture, alignment, mixing, and manifest finalization. Missing selected sources, backward clocks, format changes, write failures, stream interruptions, and mixing errors produce a recoverable error with the retained recording directory and source paths, rather than reporting complete audio.

This mix supplies the current single-input ASR/diarization pipeline. The original separate source tracks are retained for future source-aware processing. A device-format change requires a new recording. Delayed final samples from one source are represented through its timestamps, not a fabricated device-start offset. The renderer limits final timelines to 24 hours and requires additional disk space for aligned tracks and the mix.

## Verification and remaining device acceptance

Automated tests use generated PCM and real audio files. They cover source offsets, silence gaps, native-rate conversion duration/pitch, retained failures, missing selected microphone, backward timing, existing-directory protection, and CLI parsing without opening devices. Actual framework APIs compile against the installed macOS SDK.

No live audio was recorded and no privacy grant was requested during implementation. Before a production recording claim, a user must explicitly grant permissions and exercise: system playback plus speech through headphones; permission denial/revocation; selected mic absence; sleep/wake and call interruption; device-route changes; sustained recording and disk exhaustion; and playback/transcription of the saved mix against the two originals. These remain hardware/permission acceptance checks. Simulator/build success does not establish them.

## Verified Apple references

- [ScreenCaptureKit captureMicrophone](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone)
- [SCStream microphone output](https://developer.apple.com/documentation/screencapturekit/scstreamoutputtype/microphone)
- [SCStream synchronizationClock](https://developer.apple.com/documentation/screencapturekit/scstream/synchronizationclock)
- [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

Exact availability and callback signatures were also verified in the installed macOS SDK's ScreenCaptureKit/CoreMedia headers. ScreenCaptureKit microphone output is available starting macOS 15; system audio output starts macOS 13.

### Restricted test-runner diagnosis

On this development host, running the whole Speech suite inside the tool's restricted filesystem/process sandbox can hang in Apple framework initialization. A sampled stalled process showed `AudioFileFormatRegistry::AddComponentFormats` → `AudioComponentMgr_RegistrarService::retrieveComponents` → a synchronous NSXPC reply wait; other audio-file tests waited on the framework's registry mutex. This occurs before sample processing, rather than in the archive's file-reading loop. The same 42 Speech tests completed in about 0.32 seconds with the approved build execution permissions (one model smoke intentionally skipped). Use the permitted native build environment for this suite; do not suppress tests or infer hardware capture acceptance from that environment requirement.

### Native capture UI wiring

The native Mac application defaults to microphone-only capture. Selecting **Mac call audio + microphone** opts into `SystemAudioCaptureService` through the injectable `SystemAudioRecording` boundary; the start action performs permission preflight and then awaits actual stream startup. Stop awaits finalization and uses the returned `processingURL` for the existing speech pipeline. The mix is mono 48 kHz; retained raw `system.caf` and `microphone.caf` preserve each source's native sample rate and channel count. The app surfaces the recording source directory on finalization failure. A failed capture does not proceed to ASR as a successful recording.

The UI's retained-directory message is a recovery aid, not an automatic track-repair workflow. A stream/device error can leave only a valid prefix, a missing selected track, or an incomplete manifest tail after a process crash. Users must inspect the retained sources before deliberately importing or otherwise processing them; the application does not silently substitute partial system-only audio for a failed system + microphone capture. iOS continues to use its existing microphone recorder.
