# Long recording transcription repair — 2026-10-17

## Incident and preservation
An iPhone build 40 recording failed with the detected-speech coverage error. The 401.26375-second original PCM WAV was copied off the phone twice and the copies matched byte for byte. Original app data and recordings have not been deleted or overwritten. Private incident artifacts remain in ignored build storage, never in this repository.

## Repair
Replace the recording-wide maximum of twelve six-second retries with two finite passes across each unresolved speech interval (six seconds, then three seconds). Keep recognized words, preserve original timestamps, give overlap context one owner, and detect internal/trailing gaps rather than accepting an entire diarization span after a single recognized word. Authorization errors still fail immediately. Remaining detected-speech gaps of three seconds or longer still fail visibly; no fabricated text or claim of completeness.

The iPhone share menu now offers Share Original Audio even without a transcript. Sharing is explicitly initiated by the user.

## Verification
The full offline unit suite passed: 357 tests. Tests cover recovery through the final minute of a 401-second file, internal/trailing holes, no-speech and authorization failures, original offsets, and no duplicate words at retry context boundaries. Signed iPhone build 46 compiled and was installed in place. Device metadata confirms 46. The original audio was read back after installation and is byte-identical to the pre-update backup.

## Actual recording verification
Silent Mac processing of the complete 401.26375-second working copy produced 437 primary words plus 152 recovered words across 19 shorter requests. No remaining detected-speech gaps were reported. The first test exposed a second omission: the merger filtered six low-confidence words. That filtering was removed; confidence remains attached to words for review. The final run persisted all 589 recognized words, with zero exact duplicate word/timestamp entries. A timestamped transcript and timed-word JSON are saved privately alongside the recovery copies. No playback, capture or cloud transcription was used.

## Pending gate
On-device regeneration of the important recording in iPhone build 46; the phone was locked when launch was attempted, and the owner was asked to unlock and regenerate. A coverage check is not proof of word-for-word accuracy. The Mac build is Developer ID signed locally, not notarized/published in this pass.


## iPhone follow-up: sandbox relocation (build 47)
The owner reported “audio cannot be found at that path” in build 46. The preserved file remained present, but the stored absolute path referenced the pre-update iOS container. Library opening now repairs missing managed audio references against the current library's audio directory, only when the same regular filename exists. It never moves, rewrites, or deletes audio and leaves external/missing references untouched. This also supports restored libraries and the CLI. A reopen regression verifies unchanged bytes and correct exclusions. All 358 tests pass. Signed build 47 installed; device launch was blocked by the phone being locked, so native regeneration verification is still pending.

Mac build 52 separately removes the redundant Details disclosure from the processing status panel: one status message, with a second model-installation message only if different. Signed build installed locally.

## Summary follow-up (iPhone build 48)
Build 47 on the phone successfully processed the original recording and saved 591 timed words (10.32–398.06 seconds). The owner then reported synthesisDidNotConverge from summary generation. Intermediate AI drafts had been discarded when reduction did not shrink enough. Reduction now explicitly requests shorter synthesis, and bounded non-converging reduction retains the validated AI drafts from all source chunks instead of throwing or truncating source coverage. Invalid citations still fail validation.

At the owner's request, automatic AI failure no longer substitutes extractive highlights. A failed summary remains pending while the transcript stays intact. Explicit extractive mode remains distinct from AI generation.

The actual phone transcript was summarized silently using the repaired Apple on-device provider on the Mac: six AI-generated bullets, 110 words, saved privately. All 359 tests pass, including preservation of every source chunk when reduction stalls and no automatic extractive substitution on failure. Signed iPhone48 installed in place; launch blocked by locked device, owner asked to Retry AI summary only. Device summary verification remains pending. No private content was committed or uploaded.
