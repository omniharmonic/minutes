# Minutes control API

The Mac app can be driven by a local process with nobody at the screen. The clients are Omni's Python conductor, which talks to the socket directly, and Hermes, which goes through the `minutes-mcp` stdio shim. The API is **off by default**.

## Enable

- **Settings → General → Automation:** turn on "Allow local automation to control recordings". The setting takes effect immediately.
- **Or without the UI:**

  ```sh
  defaults write ai.nosaas.minutes controlSocketEnabled -bool true
  # Headless Macs also need the one-time recording consent (normally from the welcome screen):
  defaults write ai.nosaas.minutes recordingConsentAcknowledged -bool true
  ```

  Restart Minutes after a `defaults write`.
- **Rollback:** turn the toggle off, or run `defaults write ai.nosaas.minutes controlSocketEnabled -bool false`. The socket closes and its file is removed.

## Transport

- **Socket:** a Unix domain socket at `~/Library/Application Support/Minutes/control.sock`. The environment variable `MINUTES_CONTROL_SOCKET`, read by both the app and `minutes-mcp`, overrides the path. Paths must be shorter than 104 bytes.
- **Access:** the socket is created with mode `0600`. Connections from other user ids are closed immediately. Nothing listens on the network.
- **Startup:** a stale socket file left by a crash is removed. If another live server already answers on the path, Minutes does not start the listener; Settings shows the reason.
- **Framing:** newline-delimited JSON. Each line is one request and gets one response line, in order. A connection may carry many requests. Lines longer than 1 MB get a `bad_request` and the connection is closed. Malformed lines get `bad_request` and the connection stays open.

Request:

```json
{"id": <any>, "method": "<name>", "params": {...}}
```

Responses echo `id`:

```json
{"id": <same>, "ok": true, "result": {...}}
{"id": <same>, "ok": false, "error": {"code": "<code>", "message": "<human text>"}}
```

If a line cannot be parsed far enough to read its `id`, the error response has `"id": null`.

### Error codes

| Code | Meaning |
|---|---|
| `bad_request` | Malformed JSON, a missing or wrong-typed parameter, `capture_mode` other than the two allowed values, `assign` with `learn: true` on a cluster that cannot be learned from, `clip` with `max_seconds` outside 3–20, or `clip` on a cluster with no timed utterances |
| `unknown_method` | The method name is not one of the methods below |
| `busy` | A recording is active, starting or being set up, or the previous recording is still being finalized or processed. Also returned by `assign` and `clip` while that meeting is `starting`, `recording` or `processing` |
| `not_ready` | Recording consent is not acknowledged, speaker models are missing or installing, or speech recognition setup failed |
| `permission_denied` | Screen & System Audio Recording is not allowed. For `system_and_microphone`, also returned when microphone access is not granted. The API checks permissions and never prompts |
| `not_recording` | `stop` or `mark` was called with nothing recording, or `stop` was called while the recording is already stopping |
| `wrong_meeting` | `stop` named a different meeting than the one recording |
| `not_found` | Unknown meeting or cluster |
| `internal` | Anything else; the message has the details (for example, the recorder failed to start, or `clip` found no audio file for the meeting) |

## Methods

### `status`

Takes no parameters. Returns:

```json
{"recording": false, "meeting_id": null, "capture_mode": null, "duration_s": 0,
 "processing": false, "starting": false, "ready": true, "not_ready_reason": null,
 "system_audio_permission": true, "default_output_device": "BlackHole 2ch",
 "default_input_device": "BlackHole 2ch", "version": "1.0.0 (72)"}
```

- **`capture_mode`:** the mode actually in use (`microphone`, `system_audio` or `system_and_microphone`), or null when idle. A recording started from the Record button can show `microphone` after that button's permission fallback.
- **`processing`:** true while the previous recording is being finalized or processed. A `start` returns `busy` until it is false.
- **`starting`** (added field): true while a start is being set up or the recorder is starting.
- **`default_*_device`:** Core Audio device names, or null.

### `start`

Params:

```json
{"title": "Weekly sync", "capture_mode": "system_audio", "event_id": "abc", "attendees": [{"name": "Ana", "email": "ana@example.com"}]}
```

Returns: `{"meeting_id": "<uuid>", "capture_mode": "system_audio"}`

- **`title`** is required. It is stored as the meeting title and is never replaced by an automatic title.
- **`capture_mode`** is `system_audio` (the default) or `system_and_microphone`. `microphone` is refused with `bad_request`.
- **No fallback.** If Screen & System Audio Recording is not allowed, the result is `permission_denied` and nothing is recorded. The Record button in the app keeps its microphone-only fallback; the API never uses it.
- **Returns only after capture starts.** The call returns after the system recorder is running. Failures are reported as `not_ready`, `busy` or `internal`.
- **`event_id`** is stored as the meeting's `calendar_event_id`. If it matches an event Minutes has loaded (either its full occurrence id or its event identifier), that event is bound: its invitees and conference link are stored and its "record?" prompt is dismissed.
- **`attendees`** are stored as meeting invitees (people and `meeting_attendee` rows) when they have an email. Each entry needs a name or an email. Attendees without an email are only used for the display name. They are context for speaker naming only and are never treated as evidence of who spoke.

### `stop`

Params: `{"meeting_id": "<id>"}`

Returns: `{"meeting_id": "<id>", "processing": true}`

- The call returns once the audio is finalized and processing has begun. Processing (transcription, speakers, summary, automatic vault export) continues in the background. Poll `status.processing` or `get`.
- If finalization fails, the result is `internal` and the meeting's status becomes `failed`. Source audio is preserved.

### `mark`

Params: `{"label": "Decision"}` (`label` is optional; the default is "Key moment")

Returns (added fields): `{"bookmark_id": "<id>", "timestamp_s": 312.4, "label": "Decision"}`

### `get`

Params: `{"meeting_id": "<id>"}`

Returns:

```json
{"meeting": {"id": "...", "title": "...", "status": "needs_review", "started_at": 1763700000.0, "ended_at": 1763703600.0, "calendar_event_id": null},
 "clusters": [{"id": "...", "track_id": "...", "label": "Speaker 1", "speech_seconds": 81.5, "assignment": "suggested", "person_id": null, "confidence": 0.42}],
 "utterances": [{"id": 1, "cluster_id": "...", "speaker_name": "Speaker 1", "start": 0.0, "end": 4.2, "text": "..."}]}
```

- **Times:** `started_at` and `ended_at` are Unix epoch seconds; utterance `start` and `end` are seconds into the recording.
- **`speaker_name`:** the readable name the app shows, with display labels repaired.
- **Meeting `status`:** moves through `starting`, `recording`, `processing`, `needs_review`/`finalized`, and ends in `failed`/`recorded` if something goes wrong.

### `assign`

Params: `{"meeting_id": "<id>", "cluster_id": "<id>", "name": "Ana", "email": "ana@example.com", "learn": false}`

Returns: `{"cluster": {…same shape as get…}, "person_id": "<id>", "learned": false}` (`person_id` and `learned` are added fields)

- **Same path as the app.** This runs the same code as the speaker review screen and `minutes-cli assign` (`SpeakerAssignment` in MinutesSpeakerID).
- **Finding the person:** by email when one is given, otherwise by display name (case-insensitive), otherwise a new person is created. An existing person keeps their display name.
- **What changes:** the cluster gets the person, their label and assignment `user`, and every utterance of the cluster gets the name. As after a UI rename, generic labels in the summary ("Speaker 2") are rewritten and the vault note is refreshed if it was saved before.
- **`learn: true`:** also remembers the voice through `VoiceEnrollment.remember`. This needs a trained-model cluster with at least 20 s of speech; otherwise the result is `bad_request` and nothing is changed.

### `export`

Params: `{"meeting_id": "<id>"}`

Returns:

- `{"exported": true, "path": "<vault URL>", "note_id": "<note id>"}` (`note_id` is an added field)
- `{"exported": false, "path": null, "reason": "..."}` (`reason` is an added field), when no vault is connected or someone has edited the note in the vault

This wraps `saveToParachuteVault`. It updates the earlier note for the meeting instead of creating a second one.

### `clip` (build 74)

Params: `{"meeting_id": "<id>", "cluster_id": "<id>", "max_seconds": 10}` (`max_seconds` is a number from 3 to 20; the default is 10)

Returns:

```json
{"path": "/Users/…/Library/Application Support/Minutes/clips/<file>.m4a", "duration_s": 9.6,
 "segments": [{"start": 12.3, "end": 17.0, "text": "…"}]}
```

- **Which speech:** the cluster's utterances that no other cluster's utterance overlaps come first, longest first (the earlier one wins a tie); overlapped ones are used only after those. Whole utterances are taken while they fit, then the next one is cut from its start to the time left (unless less than 0.5 s is left) and selection stops. The segments are played in time order with 0.25 s of silence between them; `max_seconds` includes those gaps.
- **`segments`:** the source times (seconds into the recording) and the utterance text of each piece, in clip order. A cut piece keeps its utterance's full text.
- **`duration_s`:** the clip's length, rounded to 0.01 s.
- **Which audio:** the same file the speaker review screen plays (`SpeakerAudioSample.audioPath`): a Minutes capture's aligned per-source file (`system` or `microphone`) when the cluster belongs to one, otherwise the meeting's audio file. With a per-source file, only clusters of the same track count as overlapping.
- **File:** AAC in an `.m4a`, mono, 16 kHz, about 32 kbps. Written with mode `0600` into `~/Library/Application Support/Minutes/clips/` (mode `0700`). Every call first deletes files there older than 7 days.
- **Errors:** `not_found` for an unknown meeting or cluster; `busy` while the meeting is `starting`, `recording` or `processing`; `bad_request` when the cluster has no timed utterances; `internal` when the meeting has no audio or its file is missing.
- **CLI:** `minutes-cli clip <meeting-id> <cluster-id> [--max-seconds 10]` runs the same code (`SpeakerClip` in MinutesSpeech).

## Example

```sh
printf '%s\n' '{"id":1,"method":"status"}' | nc -U ~/Library/Application\ Support/Minutes/control.sock
```

## `minutes-mcp`

A stdio MCP server. It speaks JSON-RPC 2.0 with one message per line and supports `initialize`, `notifications/initialized`, `ping`, `tools/list` and `tools/call`. It echoes the client's `protocolVersion`, or uses `2025-06-18` if the client sends none. It depends only on Foundation.

- **Tools:** `minutes_status`, `minutes_start`, `minutes_stop`, `minutes_mark`, `minutes_get`, `minutes_assign`, `minutes_export` and `minutes_clip` (8 tools). Each takes the socket method's params as arguments.
- **Results:** the socket's `result` is returned as JSON text content.
- **Errors:** a socket error becomes `isError: true` with the text `{"error": {"code": "<code>", "message": "..."}}`. If the app cannot be reached, the code is `unavailable`.
- **Location:** `scripts/build-app.sh` bundles the binary as `Minutes.app/Contents/MacOS/minutes-mcp`. Build it alone with `swift build -c release --product minutes-mcp --package-path MinutesKit`.

Hermes (`~/.hermes/config.yaml`; Hermes adds the `mcp_` prefix to tool names):

```yaml
mcp_servers:
  minutes:
    command: "/Applications/Minutes.app/Contents/MacOS/minutes-mcp"
```

If the app is installed in `~/Applications`, use that path instead.
