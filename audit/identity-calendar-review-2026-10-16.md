# Minutes identity and calendar audit — 2026-10-16

The actual app pipeline performs trained local speaker segmentation/embedding through `FluidDiarizationBackend`, aligns recognized words to acoustic clusters, then applies `RememberedSpeakerIdentification` before saving clusters and utterances. Calendar names never directly name acoustic clusters. Each remembered match needs compatible trained-model provenance, a persisted voice sample of at least 20 seconds, probe speech of at least 5 seconds, raw similarity at least 0.88 and a competing-person margin of at least 0.12. Automatic matches do not enroll additional profiles. Explicit confirmation and Keep unknown survive refresh when compatible acoustic evidence is unchanged. People provides explicit enrollment and deletion controls; profiles remain local.

## Proven gaps repaired

- Duplicate calendar participants previously kept only the first record's self flag, display name and RSVP. Merge now enriches self/name context and retains a known invitation response when organizer metadata repeats the person with an unknown response.
- Binding calendar context previously discarded RSVP. `MeetingAttendee` now carries the response, with backward-compatible historical JSON decoding and an additive `v8_invitation_response` SQLite column. Declined invitations remain excluded from bound speaker candidates. Existing normalized-email person IDs and manually chosen names remain unchanged.
- Calendar detail now displays each invitation response and explains that RSVP does not establish attendance. Speaker review distinguishes remembered but unconfirmed matches from human-confirmed identities, explains invitees may be absent, and describes candidate associations as linked to the meeting instead of claiming they are present.

The two new regressions failed on the actual previous implementation: duplicate self/name/RSVP context was lost, and persisted attendee JSON contained no invitation response. They then passed with the repair. Additional compatibility checks exercise an actual pre-column SQLite database, update/reopen behavior, and historical JSON.

## Fresh verification

From `MinutesKit`:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/minutes-identity-clang swift test --disable-sandbox --skip-update --filter 'EventCalendarTests|InvitationResponseMigrationTests|MinutesSpeakerIDTests|RememberedSpeakerIdentificationTests|SpeakerReviewPresentationTests|TranscriptSpeakerFlowTests|IdentitySafetyTests|EligibleProfileAmbiguityTests|VoiceEnrollmentTests'
```

47 tests passed across four test executables: 29 speaker identity, 2 store/JSON compatibility, 9 calendar, 7 speaker review/app persistence. Log: `minutes-identity-targeted.log`. Initial reproduction and focused green logs: `minutes-calendar-red.log` and `minutes-calendar-green.log`.

```sh
MINUTES_MODELS=1 MINUTES_MODELS_DIR=/private/tmp/minutes-identity-models33 MINUTES_IDENTITY_FIXTURE_DIRECTORY=/private/tmp/minutes-extended-speech CLANG_MODULE_CACHE_PATH=/private/tmp/minutes-identity-clang swift test --disable-sandbox --skip-update --filter TrainedVoiceReuseAcceptanceTests
```

Installed models plus generated fixture audio only: passed in 1.449 seconds. Two explicitly enrolled profiles persisted/reopened; separate later voice turns were automatically named; transcript identities survived another reopen; no additional profiles were created automatically. Same-speaker similarities: 0.951317 and 0.967965; margins: 0.754905 and 0.820048. The wrong-person control remained unnamed despite attendee context. Log: `minutes-trained-identity-current.log`. Original acceptance JSON/log in `../../audit-2026-10-14/repair-evidence/minutes-trained-voice-reuse-acceptance.*` were also inspected before the fresh rerun.

The package and shared SwiftUI changes compiled during these runs. The initial full model-free suite under the restricted sandbox stalled in `MinutesSpeechTests` and was explicitly terminated; `minutes-identity-full-suite.log` is partial evidence, not a full-suite pass. Targeted tests and installed-model acceptance were rerun successfully with ordinary process permissions. No permission settings were modified. `git diff --check` passed for touched tracked files.

## Limits

Generated voices establish working persistence, reuse and conservative rejection plumbing, not population-level human recognition accuracy. Prior six-minute system-only evidence (`long-virtual-system-capture-build37.json`) covers all 18 generated turns and reports three acoustic clusters for two voices; minor over-segmentation remains. It is anonymous turn attribution, not known-person recognition or overlap DER measurement.

Real-human voices, noisy/overlapping speech, changed microphones/routes, long sessions and cross-device voice profile sync remain unverified. No UI interaction or usability timing was performed in this audit. New copy and RSVP storage are source changes; no application was signed, installed or deployed. No live recording, playback, personal calendar access, personal voice enrollment, network requests or external exports were performed. No transcript text, secrets or embedding vectors were logged.

## Integrated production workflow acceptance follow-up

`IntegratedTrainedIdentityAcceptanceTests.calendarThroughAppStateAndReopen` now exercises real installed Fluid segmentation/WeSpeaker embedding through `PipelineOrchestrator`, actual audio decode and transcript alignment, `CalendarMeetingBinder`, `AppState.processCurrentMeeting()`, `VoiceEnrollment.remember`, and disk-backed SQLite reopen together. The isolated generated-voice fixtures enrol the dominant eligible cluster from turns 00+02 and 01+03; no speaker counts, acoustic centroids or person assignments are forced. Two independent later turns (04+05) run together in one later meeting and receive remembered names automatically. All matching continues to use `fluidaudio-0.17.7-wespeaker-v2`, 256-dimensional profiles, 20-second enrollment/5-second probe minimums, similarity 0.88 and competing-person margin 0.12.

The test verifies normalized-email linkage to existing people, preservation of their explicitly chosen names, accepted/tentative/unknown RSVP persistence, declined invitee exclusion, and no naming from calendar context before enrollment. Repeating explicit enrollment creates no duplicate profile. Names and attendee metadata survive SQLite reopen. Subsequent actual trained processing preserves explicit confirmation and Keep unknown when acoustic evidence remains identical. Removing one remembered voice leaves its different generated voice unnamed despite calendar attendee context; forgetting all profiles prevents recognition in a new meeting. Deleting an enrollment meeting preserves the explicitly remembered profile and its ability to identify another independent generated turn (08). All assertions passed.

Fresh command from `MinutesKit`:

```sh
MINUTES_MODELS=1 MINUTES_MODELS_DIR=/private/tmp/minutes-identity-models33 MINUTES_IDENTITY_FIXTURE_DIRECTORY=/private/tmp/minutes-extended-speech CLANG_MODULE_CACHE_PATH=/private/tmp/minutes-identity-clang swift test --disable-sandbox --skip-update --filter IntegratedTrainedIdentityAcceptanceTests
```

Final clean run: **1 test passed, zero failures, 4.267 seconds**, process exit 0. Log: `audit/minutes-integrated-trained-identity-current.log`. Ordinary local process permissions were used for Core ML cache access; the initial restricted run also passed, with noisy denied-cache diagnostics and slower inference. No permission settings were changed.

The acoustic limitation remains measurable: the two enrollment recordings produced 1 and 2 clusters respectively; the later two-voice meeting produced 3 clusters. Amber's later turn had 100% correct named aligned duration; Rowan's had 94.3396%, with 0% assigned to the other known name. The remaining approximately 0.9 seconds stayed anonymous. These figures measure deterministic fixture-token alignment on generated voices, not ASR word accuracy, real-human recognition, overlap DER, or a population wrong-name rate.

**Recognition limitation:** the test intentionally injects deterministic timed fixture tokens through `SpeechTranscriptionBackend`; it never invokes Apple Speech or requests Speech consent. Actual trained diarization, matching, word-to-cluster alignment and app persistence run unchanged, but actual ASR and native UI interaction are outside this test's evidence. Summary generation uses the local deterministic extraction fallback in isolated preferences. No physical microphone/camera capture, audio playback, real calendars, user recordings, normal application database, tokens, network access, or external exports are used.

A related UI wiring defect was identified by the coordinating agent: Review's prior “Lock & remember” callback saved raw voiceprints directly, bypassing `VoiceEnrollment`'s stale-sample check and deduplication. Its repair routes that callback through the shared enrollment API. The integrated suite proves the shared API's repeat-enrollment idempotence and the production AppState reuse path; it does not simulate a native click on that callback.
