# Voice reuse investigation — Mac build 49

## Findings

The owner supplied a new, explicitly confirmed baseline and a separate untagged recording. The existing database contains a new compatible 56.4-second owner profile. The untagged recording's main cluster was already automatically assigned to the owner by the batch pipeline. Its cosine similarity was 0.9458 to the new profile and 0.6673 to the earlier compatible profile. The two owner enrollment vectors themselves were only 0.6587 similar. These are similarities, not confidence probabilities. This demonstrates that the earlier enrolled evidence was not representative of this new sample; it does not establish why the historical recording differed. No profile was deleted or replaced.

Fresh, local, read-only audio analysis in a new process reproduced one owner match covering 35.7 of 40.0 detected speech seconds. A separate 4.3-second cluster remained unnamed. This is not proof that this short cluster belongs to another speaker. Whole-meeting and live naming reuse the same persisted, compatible, explicitly enrolled profiles.

The untagged recording, split into ten-second live windows, produced three owner matches, one weak/ambiguous abstention and one tail shorter than the five-second minimum. There were no other-person assignments. An independent 110-second generated two-voice/silence fixture produced zero assignments to the owner (or another stored person) across eleven windows. These are limited acceptance samples, not a population accuracy estimate. Automatic identification cannot be promised to be perfect; ambiguous, mixed, noisy and insufficient speech must still abstain.

## Repairs

- Live caption inference previously discarded every incoming window while a prior inference was busy. It now drains a FIFO with four bounded pending windows. Overflow is visible instead of silent; capture and text recognition continue independently.
- Pending inference reads current profiles and people rather than freezing them at caption startup. A result is discarded if its person's profile set changed or the person disappeared during inference.
- Live results carry stable person IDs; local verification compares IDs rather than display names. Two people sharing a name cannot produce a false positive in the audit.
- Final preview/recording caption completion waits for the bounded identity work. Closing/restarting captions clears pending audio and invalidates old results.
- `voice-audit-file` exposes fresh batch diarization + remembered naming without saving meetings or profiles. Existing `caption-voice-file` verifies the live path. Neither performs enrollment. Audio, transcript text and vectors are not included in committed evidence.

No identity thresholds were lowered: batch matching retains 0.88; live matching retains 0.90, with 0.12 separation from the next person and existing speech/consistency requirements. Calendar context never substitutes for acoustic evidence. Legacy/incompatible vectors remain excluded.

## Verification

- 352 model-free tests passed, including busy-window retention, explicit overflow, reset, invalid PCM, stable identity and identical competing profiles.
- iOS simulator compatibility build passed.
- Mac build49 Developer ID signed, notarized, stapled and installed. Installed executable matches the package and strict code-signature verification passes.
- After app restart, the actual native caption panel silently processed the untagged recording: three owner labels visible, five recognition sessions, zero retries, zero dropped batches. No personal transcript content was printed or captured into evidence.
- Preview closed afterward; normal library remained at 256 meetings and 46 voiceprints. All testing was local and silent; no microphone or playback.

## Follow-up condition matrix (build50 work)

Six local transformations of the independent, untagged owner recording were tested against unchanged profiles. No transformed sample was enrolled. White noise SNR is relative to whole-file RMS, not speech-only RMS; the telephone filter is a 300–3400 Hz band limit, not an actual Bluetooth codec/device test.

| Condition | Batch owner speech / detected speech | Live owner windows / all windows | Wrong-person assignments |
|---|---:|---:|---:|
| Original | 35.7 / 40.0 sec | 3 / 5 | 0 |
| −18 dB level | 36.8 / 41.1 sec | 3 / 5 | 0 |
| +6 dB level | 35.7 / 40.0 sec | 3 / 5 | 0 |
| Telephone-like band limit | 32.5 / 36.8 sec | 0 / 5 | 0 |
| White noise, 20 dB SNR | 0 / 39.4 sec | 0 / 5 | 0 |
| White noise, 10 dB SNR | 0 / 38.6 sec | 0 / 5 | 0 |

An FFmpeg spectral-denoising experiment (`afftdn=nr=20:tn=1`) did not recover noise matches and lost the telephone batch match. It is not shipped. No thresholds were lowered. This fails the broad reliability acceptance gate despite safe abstention; noise-robust embedding/preprocessing and representative multi-condition enrollment require further held-out positive and negative evaluation. Real AirPods/room/distance/device and multi-human recordings remain untested conditions. No claim of consistent cross-condition reliability is warranted.
