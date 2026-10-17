# Cross-device voiceprint sync: options and privacy boundary

Research date: **2026-10-17**. Research only; no sync implementation or account configuration was changed. This concerns one person's Minutes installation on their own Mac/iPhone, not sharing other people's biometric profiles with collaborators.

## Recommendation

Keep voiceprints device-local by default. A future opt-in should say **“Sync remembered voices across my devices”**, explain where encrypted data goes, allow individual deletion, and never be bundled with note export, calendar access or server recording. Prefer a same-user CloudKit private-database prototype for the Apple-only product. Evaluate a Prism encrypted-blob transport only if independence from iCloud or a user-owned server is a real requirement. In either case, design key distribution and deletion before adding a network uploader.

“Private CloudKit database” and “encrypted at rest” do not by themselves establish end-to-end encryption. Apple says third-party CloudKit encrypted fields/assets gain E2EE under Advanced Data Protection; ordinary account protection is a different security model. For an E2EE product promise independent of that setting, encrypt payloads on the client with a key that the storage server does not possess. [Apple iCloud security and third-party data](https://support.apple.com/en-us/102651).

## Actual Minutes baseline

The inspected implementation persists vectors in the local SQLite `voiceprint` table (`MinutesCore/Store.swift`): person ID, model identifier, dimension, vector blob, speech duration and creation time. Current source identifies the trained family as `fluidaudio-0.17.7-wespeaker-v2` (`MinutesCore/SpeakerEmbeddingModel.swift`). `VoiceEnrollment.remember` is an explicit user action, validates trained 256-dimensional finite embeddings and at least twenty seconds of speech, then stores an L2-normalized vector. Matching reads consented stored profiles; it does not create profiles implicitly.

The inspected store binds serialized vector bytes into SQLite; it does not demonstrate application-layer per-vector encryption. Platform file protection and full-disk protection must not be represented as a newly verified encrypted database feature. Sync must add its own cryptographic boundary. The experimental spectral embedding in `EmbeddingService.swift` is explicitly marked unsuitable for persisted biometric voiceprints.

These current code facts are more specific than the original PRD's proposals for automatic calendar-attendee enrollment. Preserve the implemented explicit enrollment semantics.

## Decision matrix

| Option | Advantages | Cost and limits | E2EE claim that is supportable |
|---|---|---|---|
| Device-local only | No new server data exposure or sync operation; clear deletion | Enroll/identify separately per device | No cloud transport; do not call this synchronization |
| CloudKit private DB, native encrypted fields/assets | Apple identity, private per-user database, Apple sync APIs; no custom backend | iCloud account/storage/network constraints, entitlements and schema migration; ADP-dependent protection | Describe native encrypted fields accurately; E2EE only with appropriate ADP conditions |
| CloudKit private DB + application-encrypted payload | Same-user Apple infrastructure while server stores ciphertext | App must solve key wrapping, recovery, device enrollment, metadata minimization and rotation | Payload E2EE if only trusted client devices hold decryption keys; server metadata still exists |
| Prism opaque encrypted blobs | User-owned backend, flexible devices/hosting, can align with existing pairing | New sync protocol, authorization, key management, backup/retention and maintenance | Payload E2EE only if Prism never gets decryption keys; server-side disk encryption alone is insufficient |
| Clear vectors through note exports/shared vault | Easy to wire accidentally | Violates adapter boundary and exposes reusable biometric profiles | Reject |

CloudKit has a per-user private database and encrypted field support. Apple's sample demonstrates `CKRecord.encryptedValues` and notes that existing schema fields cannot simply be changed to encrypted fields. New record types/fields and migration need planning. These public APIs establish a storage mechanism, not a completed Minutes conflict/deletion engine. [CloudKit private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase), [Apple encryption sample](https://github.com/apple/sample-cloudkit-encryption), [CloudKit encrypted data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data).

## A compatible envelope

Proposed application-encrypted payload, not a database migration specification:

- Stable random profile ID and person ID within the user's Minutes library; no email-based filename or public biometric identifier.
- Schema version, full embedding-model family/revision/hash, preprocessing and normalization version, dimension, numeric format and channel/domain provenance.
- Vector, speech-quality metadata needed for matching, user consent purpose/time and origin device identifier inside the ciphertext.
- Revision/causal metadata, encrypted creation/update time where possible, deletion/tombstone marker, key version and authenticated associated data binding owner/library/profile/schema.
- Bounded opaque transport metadata outside encryption: random object ID, ciphertext length, revision and necessary routing fields. Document that timing, size, access patterns and account association may remain visible.

A 256-element Float32 vector is approximately 1,024 bytes before metadata and encryption overhead. Storage volume is therefore not the main difficulty; correct identity, compatibility, consent, keys and deletion are.

Do not sync raw source audio by default. A saved voiceprint does not contain a usable audio sample and should not imply permanent retention of enrollment speech. If the user separately opts into sample-audio sync, specify codec/sample rate, speaker consent, retention and deletion as a distinct content type. Do not retain audio merely because a streaming diarizer could use it for priming. Meeting and transcript sync are separate purposes too.

## Model compatibility must be strict

Same dimension does not mean same embedding space. Match only when model family, model artifact revision, preprocessing, normalization and dimension agree. Never compare legacy untagged vectors, synthetic spectral vectors, WeSpeaker vectors and Sortformer internal state as if they were interchangeable. Preserve the existing trained model tag; enrich it with artifact identity before general cross-version synchronization.

For a future model change, keep incompatible profiles quarantined or in a separate model namespace. Re-enroll on the new model, or re-embed separately retained/authorized source audio. Do not invent an embedding-space conversion. Cross-device microphone acoustics and compression can change match behavior even with identical model bytes; measure Mac-to-iPhone and iPhone-to-Mac precision independently. Calendar identity remains a prior, not an acoustic enrollment source.

Keep person matching separate from vector matching. Local person IDs need stable sync identity, merge history and reversible user corrections. Two contacts with the same display name must never merge automatically. Email can be an explicit user-reviewed hint, not a public lookup key for biometric data.

## Keys and trust boundaries

For app-encrypted sync, use an authenticated-encryption construction from a reviewed platform library, with unique nonces and versioned keys. Use OS Keychain for device secrets. Do not store an unwrapped library key beside the blobs, in a Prism vault accessible to server workers, in logs, or in agent context. A scheme where the server decrypts embeddings for recognition is server processing, not same-user device E2EE. [Apple CryptoKit](https://developer.apple.com/documentation/cryptokit), [Keychain Services](https://developer.apple.com/documentation/security/keychain-services).

Two plausible key-distribution designs need a threat-model spike: an iCloud Keychain synchronizable key for the same Apple account, or device pairing with a trusted device wrapping a library key to the new device's public key. Neither should be assumed safe merely because the storage is CloudKit/Prism. Define device replacement, all-devices-lost recovery, device revocation, account sign-out and key rotation. Explain when deleting a device blocks future access versus when already downloaded plaintext cannot be recalled.

Prism should authorize only opaque object synchronization for the user's library. Use a new scoped capability/purpose; existing note export tokens and `MeetingExportBundle` are not authorization to move voiceprints. Omni may coordinate status at most; neither embeddings nor enrollment samples should enter its prompts. Keep biometric content and detailed identity-match decisions out of analytics and default logs.

## Deletion and conflict rules before implementation

Define deletion as removal of local active profiles plus a tombstone that prevents an offline device from resurrecting a deleted profile. Bound tombstone retention against the maximum supported offline duration; a device absent beyond that duration must rebootstrap. A global “Forget this voice on all my devices” action is distinct from disabling sync or removing this device's cache.

Preserve immutable enrollment samples/vectors as separate profile records rather than silently averaging concurrent updates. Choose deterministic rules for profile deletion versus enrollment, person merge/unmerge and consent withdrawal. A deletion should dominate older updates. Do not automatically upload old local profiles when a user enables only people/contact sync. Include backup/restore handling: explain what can remain in provider backups and how app key deletion affects recoverability without claiming immediate physical erasure everywhere.

## Proposed research gates

1. **Threat model and product consent:** one user, trusted devices, storage provider visibility, backups, metadata and loss/recovery; exact opt-in copy and independent delete actions.
2. **Compatibility fixture:** two devices exchange a synthetic encrypted test profile; invalid model/dimension/schema/ciphertext/account is rejected without logging payloads. No real biometric data is needed for protocol tests.
3. **Key recovery/revocation:** pair second device, lose one device, rotate key, deny revoked device, recover according to stated policy. Document limits for already downloaded data.
4. **Offline conflict/delete:** simultaneous enrollment, person rename/merge, deletion while another device is offline, old backup restore. Deleted profiles never silently return.
5. **Cross-device acoustic evaluation:** consenting recordings and a held-out speaker set; correct names, wrong names and abstention reported separately for both directions. Encryption success does not establish recognition accuracy.
6. **Privacy review:** confirm no vectors/audio in export adapters, normal logs, test artifacts, crash reports or orchestration prompts; show server stores ciphertext only under the selected model.

Only after those gates should a future ADR select CloudKit or Prism and define append-only schema changes. This research does not implement MN-7.1 or broaden the existing local-first network policy.
