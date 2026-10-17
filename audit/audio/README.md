# Controlled audio acceptance

These scripts generate fictional speech using installed macOS Samantha/Daniel voices and analyze only a meeting ID explicitly selected by the operator. They do not enroll or name people, print embedding vectors, modify the database, use network ASR, or export audio/transcripts.

Run from the workspace root with Python3 plus NumPy/SciPy and the local FFmpeg executable at the path in the analyzer. The generator writes a354.6-second mono16kHz fixture,18speaker turns and ground truth in `/private/tmp/minutes-extended-speech`. It also records the fixture manifest in the audit evidence folder. No voice downloads occur.

1. Run `python3 minutes/audit/audio/generate-controlled-conversation.py`.
2. In the installed Minutes app, explicitly start Microphone or Mac call audio + microphone. Confirm the desired hardware route. Play the generated WAV with `afplay` and stop after playback completes.
3. Wait for local processing to finish, then run `python3 minutes/audit/audio/analyze-controlled-capture.py --meeting-id SYNTHETIC_MEETING_ID --output-dir audit-2026-10-14/extended-capture-evidence`.

Results include source track lengths/gaps, known-signal correlation at the first/last turns, drift, transcript coverage/normalized word error and permutation-matched speaker consistency. Near-zero correlations mean the stimulus was not captured on that track. Missing source duration is a capture failure even if speech was recognized from another track. Controlled generated non-overlapping voices are not a substitute for real multi-person, overlapping, noisy or hour-long meetings; speaker consistency on recognized utterance overlap is not benchmark DER.

The pipeline's production automatic-clustering threshold is checked separately by the opt-in `RealDiarizationDiagnosticsTests` against installed model weights. The controlled stimulus contains no overlapping speech and no real enrolled identity. A synthetic voice must not be silently enrolled as a real person. `minutes-cli suggest-title <meeting-id>` prints a grounded local title without renaming an existing meeting; CLI `process` applies the same conservative remembered-voice policy as the app.
