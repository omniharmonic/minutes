# Optional self-hosted meeting capture: research and gates

Research date: **2026-10-17**. Research only; no connector, credentials, bot, deployment, or account setting was created. Platform availability must be checked again before implementation. “Verified” below means documented public behavior, not a successful test against the owner's account. Proposed architecture and acceptance thresholds are design recommendations.

## Recommendation

Keep Minutes the recording and transcript product. Offer a separately enabled **Minutes Server** capture add-on, with Prism providing server authentication, secret storage and vault integration, and Omni optionally scheduling jobs. Neither Prism nor Omni should become the recorder's identity or a mandatory dependency for local recording.

Start with a **Zoom RTMS eligibility spike** and **Google Meet post-meeting artifact import** where the organizer's account supports it. A universal server bot that joins arbitrary Meet and Zoom calls is **not established by current supported APIs**. Two important changes make older bot tutorials misleading:

- Google currently says its Meet Media API preview is **closed to new signups**. The documentation was updated October 1, 2026. An existing eligible preview account is a prerequisite, not something a Calendar OAuth client unlocks. [Google Media API overview](https://developers.google.com/workspace/meet/media-api/guides/overview).
- Zoom's current Linux SDK guide states: “The Meeting SDK is designed for human use cases and does not support bots or AI notetakers.” It directs these uses to RTMS. Treat Linux raw-recording bot code as historical technical evidence, not permission to ship a bot. [Zoom Linux Meeting SDK](https://godevelopers.zoom.us/docs/meeting-sdk/linux/).

This future direction changes the PRD's explicit v1 non-goals (“Meeting bots” and “no custom server ever”). Those are still the shipped scope; approve a future ADR and narrow network exception before building. Do not silently expand the local-first promise.

## Capability and decision matrix

| Route | What it provides | Current gate | Minutes decision |
|---|---|---|---|
| Mac local mic + system audio | Audio captured on the user's Mac; platform-independent call audio | Mac present, audio permission, routing and capture QA | Default route |
| iPhone in-person mic | Room microphone recording | Permission, audio-session availability, background recording setup | Default phone route; not capture of another calling app |
| Google Meet REST API | Meeting metadata, participants and generated artifacts | User OAuth, resource permissions; transcript/recording generation depends on organizer entitlement | Useful artifact importer, not live raw audio |
| Google Meet Media API | Real-time audio/video + participant metadata through WebRTC | Existing preview access; restricted OAuth; admin/meeting consent and eligibility | Blocked for a new general rollout; discovery only |
| Google Meet automated browser participant | Potentially UI-based audio collection | No general official bot SDK established here; login, waiting-room, policy and browser stability unresolved | Speculative; no promised product route and no bypass of controls |
| Zoom Linux Meeting SDK | CLI/native meeting client and raw-recording sample | Current usage policy excludes bots/AI notetakers | Do not choose for Minutes bot |
| Zoom RTMS | Server receives meeting audio and optionally video/transcript without a recorder participant | Eligible paid account + Developer Pack, app install/scopes, host/admin permissions, participating user requirements | Preferred Zoom research route |
| Hosted recording SaaS | Vendor-managed recording | Additional processor, recurring fees and data exposure | Not the default recommendation |

## Google: REST, artifacts and media are separate products

### REST is not a media receiver

The REST API creates/manages meeting spaces and accesses conference records, participant records and artifacts. Its existence does not provide the audio stream needed for Minutes' own ASR. A Meet link in Calendar is discovery metadata, not media authorization. [REST overview](https://developers.google.com/workspace/meet/api/guides/overview).

For an artifact-first prototype, ask the organizer to enable transcription in an entitled meeting and then import transcript entries when available. Google lists Business Standard/Plus, Enterprise Starter/Standard/Plus, Teaching and Learning Upgrade, Education Plus and Workspace Individual as supported transcription editions. Availability also depends on admin/host settings and storage. Transcription must actually start; merely attending does not guarantee an artifact. The participant UI indicates transcription, and admin policy can require explicit consent. This is Google's cloud transcript and must be identified as such in provenance. It cannot train a voiceprint without authorized source audio. [Transcription support and editions](https://support.google.com/meet/answer/12849897?hl=en).

Meet retains REST transcript entries for **30 days after the conference ends**; the generated document has its own Drive retention and may later diverge after editing. Preserve artifact IDs, language, participant references and timestamps; make imports idempotent and respect deletion. [Artifact lifecycle](https://developers.google.com/workspace/meet/api/guides/artifacts).

New authorization is required: REST conference access uses a Meet scope such as `https://www.googleapis.com/auth/meetings.space.readonly`. Downloading original Drive files requires an appropriate Drive scope, potentially the narrower `drive.meet.readonly`; it is distinct from Calendar access. These may bring verification/security-assessment requirements. Domain-wide delegation is administrator-granted impersonation, not a default credential shortcut. [Meet REST authorization](https://developers.google.com/workspace/meet/api/guides/authenticate-authorize).

### Real-time Media API is eligibility-gated

Existing preview access is necessary. Current overview describes organizational consent: a person from the meeting-owning organization must be present to consent; for a Gmail-organized meeting the initiator must be present. Host settings can reject or stop access, and participants can stop it. Encrypted/watermarked meetings and underage accounts impose restrictions. Do not repeat the older blanket claim that every participant must join the preview as a current fact; current public pages describe eligibility differently. Confirm exact tenant/project enrollment with Google before any spike. [Media lifecycle and consent](https://developers.google.com/workspace/meet/media-api/guides/overview).

The audio-only restricted scope is `https://www.googleapis.com/auth/meetings.conference.media.audio.readonly`; the Media guide additionally names `https://www.googleapis.com/auth/meetings.space.read` for negotiation metadata. **That spelling differs from the REST guide's `.readonly` scope.** Revalidate the accepted scope set in the approved preview; do not guess or substitute. Restricted scope handling can require verification and a server-data security assessment. The receiver is a WebRTC client, not a REST download; Google's technical requirements include supported codecs/header extensions and client metrics, and exclude some hardware/mobile configurations. [Media requirements and scopes](https://developers.google.com/workspace/meet/media-api/guides/get-started).

Google multiplexes participants into virtual streams. Stream identity is not person identity; map source metadata/CSRC over time rather than assuming one stream per person. Relevant-stream limits also mean “complete isolated audio for everyone” is not a safe promise. [Media stream concepts in overview](https://developers.google.com/workspace/meet/media-api/guides/overview).

## Zoom: use RTMS research, not legacy bot assumptions

### Linux SDK technical history and current policy

Zoom publishes a Linux raw-recording sample with Docker/PulseAudio support. It demonstrates that headless technical capture has existed; it does not establish current bot eligibility. In a permitted human-client use case, raw recording additionally depends on meeting recording privileges, not just joining successfully. [Official raw-recording sample](https://github.com/zoom/meetingsdk-linux-raw-recording-sample), [recording privilege API](https://marketplacefront.zoom.us/sdk/meeting/linux/class_i_meeting_recording_controller.html).

SDK authorization and OAuth are distinct: a server-generated SDK JWT authenticates the SDK app; user-associated ZAK/OBF tokens are used for relevant user/external-meeting flows. Current authorization documentation requires Zoom review for meetings outside the developer account and user authorization, with publishing/unlisted/ISV routes. An OBF-associated user must already be in the meeting and its client must leave when that user leaves. Waiting rooms, passcodes, registration and meeting security still apply. None of those credentials override the current no-bot policy. [Meeting SDK authorization](https://developers.zoom.us/docs/meeting-sdk/auth/).

### RTMS is a server media connection, not a joining bot

Current Zoom troubleshooting says **Basic accounts are unsupported**; Pro, Business and Enterprise require an active **Developer Pack**. Billing, trial expiry and stream concurrency are genuine operational gates. Self-hosting does not make platform media access free. Check the actual developer/meeting account combination with a controlled test before promising coverage. [RTMS compatibility](https://developers.zoom.us/docs/rtms/troubleshooting/).

Create a **user-managed General app**, enable RTMS started/stopped events, and request only needed granular scopes: `meeting:read:meeting_audio` for audio; optionally `meeting:read:meeting_transcript` for Zoom-generated text. Starting/stopping via REST additionally uses `meeting:update:participant_rtms_app_status`. REST initiation requires an invitee who has already joined, rather than an arbitrary shared-link attendee. [RTMS app configuration](https://developers.zoom.us/docs/rtms/meetings/add-features/).

Hosts/admins control start and auto-start behavior; participant streams require host permission where configured. Backend start does not remove those requirements. Verify webhook signatures, establish signed signaling/media connections, and honor pause/stop events immediately. Use visible Zoom disclosures plus Minutes' explicit recording controls; API authorization alone does not substitute for participant awareness. The stream lifecycle guide also requires the host or designated alternative host present for its REST start route. [RTMS lifecycle and consent controls](https://developers.zoom.us/docs/rtms/meetings/work-with-streams/).

Distribution to external users requires Zoom app review; the private self-hosted prototype is not evidence of public distribution approval. [RTMS review](https://developers.zoom.us/docs/rtms/meetings/submit-app-review/).

## Minimum new infrastructure and credentials

These are proposed requirements, not evidence that Prism already implements them.

| Component | Minimum addition | Ownership and constraint |
|---|---|---|
| Minutes app | Explicit “Use my server for this meeting” flow, server pairing, durable job/status/import model | Remains fully useful without server; user can stop/revoke |
| Prism | Authenticated device/session identities; separate encrypted provider-token vault; scoped job authorization | Do not reuse a general vault-write token as unrestricted media access |
| Minutes Server worker | Long-lived process for streaming sockets; durable job DB/queue; encrypted chunk storage; per-job limits and cleanup | A short-lived request function alone cannot own a whole meeting |
| Network | Reachable HTTPS OAuth callback/webhook route, validated certificates; outbound provider WebSockets/WebRTC as applicable | Tailscale/LAN app access alone does not make Zoom's webhook reachable |
| Zoom | General app client ID/secret, authorized user's OAuth access/refresh tokens, event webhook verification secret/token, RTMS entitlements/scopes | Store server secrets in vault; never ship client secret in iPhone app |
| Google REST | Enabled Meet API, separately authorized Meet scopes; web OAuth callback/client for server-owned grant; Drive only when needed | Native Calendar client/tokens do not automatically become server credentials |
| Google Media | Existing preview project eligibility + approved restricted scopes and compliance process | Do not provision before gate is satisfied |
| Omni (optional) | Schedule/dispatch bounded job request and read status | No provider secrets or raw audio in agent prompts/context |
| Delivery | Signed result manifest, authenticated resumable download/import, content hashes, deletion acknowledgment | App verifies tenant/device/job binding; exports stay explicitly configured |

Prefer recording encrypted audio on the server and processing on a paired Apple device after download for the first spike. FluidAudio's CoreML/ANE stack is not a Linux server inference engine. Server ASR would require a separately evaluated runtime/model and changes the processing disclosure. If a Mac worker is chosen instead, measure always-on availability and OS permission behavior.

Proposed state machine: `requested → awaiting_user_or_host → connecting → capturing → stopped → transferring → imported`, with explicit `denied`, `unsupported`, `failed`, `partial` and `expired` outcomes. A scheduled job is not “recording” until received audio advances. Use provider event IDs plus Minutes job IDs for idempotency and deduplicate reconnects. A gap manifest is preferable to silent fabricated continuity.

## Why a server helps iPhone calls, and its limit

Apple documents that an app cannot capture the active call's microphone; activating a recording audio session while another app hosts a call can fail with insufficient priority. Background mic permission is not system-call capture permission. A permitted server media receiver can capture the meeting independently of that phone's local audio session, but still needs platform eligibility, a participating user where required and host consent. It does not provide universal PSTN/FaceTime recording. [Apple audio-session activation](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:)).

## Staged research spikes and acceptance gates

| Stage | Work after separate implementation authorization | Gate to advance |
|---|---|---|
| 0. Eligibility inventory | Record account plan, app type, Google preview status and host/admin restrictions without changing production settings | Written supported-route matrix for owner's actual accounts; Google blocked if preview unavailable |
| 1. Controlled Zoom audio-only session | Consenting test participants; host approval; receive audio with timestamps; explicitly stop | Correct start/stop/denial UI; zero audio before authorization or after revoke; one intact local import |
| 2. Google artifact import | Entitled host creates transcript; import with Meet-only minimum scope | Import once despite retries; missing/late/deleted artifact is clear; transcript provenance retained |
| 3. Failure and long session | At least 60 minutes; disconnect/reconnect; duplicate webhook; host denial/leave; app user leave; token expiry | No duplicate jobs, all gaps visible, recovery preserves committed chunks, orphan worker self-terminates |
| 4. Security and retention | Cross-user request attempts, signed webhook replay, URL validation, secret rotation, revoke and deletion | No cross-tenant access; no media/tokens in logs/prompts; bounded retention and backup policy demonstrated |
| 5. Cost and device delivery | Measure egress, encoded/raw bytes, storage lifetime, worker CPU/memory, platform usage charges | Per-hour cost + concurrent-session limits documented; spending/duration caps; resumable phone/Mac import |
| 6. Product scope decision | Review evidence and draft updated PRD/ADR; request distribution approval where required | Explicitly approved network/privacy boundary; no general-availability claims before eligibility and review |

Proposed reliability target: a 60-minute test preserves every received chunk across one worker restart; unexplained loss is zero; provider/network loss is represented as gaps. Proposed usability target: status distinguishes waiting, recording and stalled audio within five seconds. These are future test targets, **not measured results**.

Biometrics remain on device unless the user separately enables the dedicated sync purpose described in [voiceprint sync options](voiceprint-sync-options-2026-10-17.md). Finished-note export authorization never authorizes uploading voiceprints. Consent copy must explain that the user's server receives audio and whether the platform itself generates a cloud transcript. No third-party recording vendor is needed as the default architecture.
