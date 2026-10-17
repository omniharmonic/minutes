# Caption stability and personal profile check — Mac build48

## Changes

The proven ten-second recognition/identity windows remain enabled when saved profiles exist (45 seconds without profiles). Digital silence below -80dBFS does not start another recognition request. Active requests continue receiving all PCM. An error after at least two seconds of digital silence is treated as a quiet ending and waits for speech; failures with recent signal still retry/back off and eventually pause. A successful final result accompanied by an error is final, not a retry. Genuine new progress clears the waiting/reconnect notice.

Caption history now inserts late final results chronologically. Pending identity labels survive text arriving later. Preview completion reports recognition-session, retry and dropped-batch counts. Scheduled windows are distinct from failure retries; the app does not promise one uninterrupted recognition request.

A 40-second recognition experiment with timestamp-based ten-second text grouping reported zero retries but failed native text-retention checks. It was rejected. The installed final build must use the short-window implementation. Do not report the experimental request-count reduction as shipped functionality.

The CLI `caption-voice-file` reports aggregate abstention reasons and supports `--expect-person <local-person-id>` for local, counts-only verification. It never enrolls profiles or changes meeting content.

## Personal-profile check

The owner authorized testing existing recordings against the saved profile. Two recordings created after the compatible saved profile were analyzed locally and silently. No raw recordings, transcript text, or voice vectors are included in this report or committed as evidence.

- Recording A:5 windows,0 matches;3 mixed/undetected-speech abstentions,1 weak/ambiguous match,1 insufficient-length tail.
- Recording B:4 windows,0 matches;2 insufficient-speech abstentions,2 weak/ambiguous matches.
- Neither recording was named as another person. No enrollment, threshold relaxation, or reassignment was performed.

**Personal live naming is not yet validated.** Loading/reusing the stored profile works, but this evidence does not establish reliable recognition of the owner. The synthetic two-voice success from build46 must not be presented as proof of real-human accuracy. Finer-grained attribution and representative clean enrollment remain follow-up work; do not automatically train from these unconfirmed live results.

## Verification

- 349 model-free tests passed; iOS simulator compatibility build passed.
- Mac build48 signed, notarized, stapled and installed. Installed executable matches the packaged binary; strict signature verification passes.
- Installed native file preview processed 110 seconds (80 seconds of generated fixture audio followed by 30 seconds of digital silence): 8 recognition sessions, 0 failure retries, 0 dropped batches. Earlier opening phrases remained scrollable after completion; final fourth-turn text remained at the end. This is a retention/stability check, not a word-accuracy benchmark.
- The CLI built successfully, but its separate Speech authorization was denied; that attempted recognition run is not counted as passing. Native UI initially stalled in the file picker; keyboard confirmation succeeded and the installed app completed the test above.
- Preview closed afterward; normal library remained at 254 meetings. No recording was created, no microphone opened and no physical playback occurred. Personal recordings are never saved into committed test fixtures.
