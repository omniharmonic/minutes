# iCloud sync setup

Minutes syncs each person's library through their own private iCloud database
(CloudKit, via `CKSyncEngine`). There is no Minutes server and no cost to the
developer; data counts against the person's iCloud storage. Sync is off until
the person turns it on in Settings → Sync.

## What syncs

| Synced | Never synced |
|---|---|
| Meetings: title, times, status, notes, Recently Deleted state, folder | Voiceprints and speaker voice embeddings |
| Transcript, summary, moments, invitees | Parachute/Prism/Google credentials and export queues |
| Speaker names and assignments (without embeddings) | Recordings in progress |
| Folders and people | Recordings, unless "Include recordings" is on (compressed `.m4a` up to 250 MB) |

Edits made on two devices merge field by field. When both changed the same field, the other device's value wins. The exceptions are notes, where both versions are kept, and moments, where both sets are kept. A meeting permanently deleted on one device goes to Recently Deleted on the others.

## Setup (done 2026-10-20)

- **Container and capabilities:** Xcode automatic signing registered the container `iCloud.ai.nosaas.minutes` and the iCloud capability on `app.minutes.ios` the first time it built the entitlement.
- **Mac Developer ID profile:** SwiftPM can't request profiles, so a throwaway Xcode Mac target with bundle id `ai.nosaas.minutes` and the iCloud entitlement was archived unsigned. The archived app was then ad-hoc signed with the entitlement and exported with `method=developer-id, signingStyle=automatic`. Xcode created "Mac Team Direct Provisioning Profile: ai.nosaas.minutes", including the container, with environment Production. It is kept outside the repo at `build/signing/Minutes_DeveloperID.provisionprofile`; to regenerate it, repeat the export.
- **Schema:** `docs/cloudkit-schema.ckdb` holds the record types Meeting, Folder, Person and Audio. Each has a `payload` asset and a `schema` INT64; Audio also has an `audio` asset. It was imported with `xcrun cktool import-schema` (using a management token saved with `cktool save-token`) and deployed to Production in CloudKit Console. Any later schema change goes the same way, and fields can only ever be added.
- **Environment:** every build uses the Production environment. Developer ID is always Production, and the iOS entitlement sets `com.apple.developer.icloud-container-environment = Production` explicitly, so development-signed iPhone builds share data with the Mac.

## Building

```sh
MINUTES_CLOUDKIT_PROFILE=$PWD/build/signing/Minutes_DeveloperID.provisionprofile \
DEVELOPER_ID_APPLICATION="Developer ID Application: <name on your certificate> (83Y42N33H8)" \
MINUTES_BUNDLE_GOOGLE_REGISTRATION=1 ./scripts/build-app.sh
```

iOS has the entitlement in `Apps/project.yml`, so builds made with `-allowProvisioningUpdates` sign it automatically. A Mac build without the profile still works, but sync is unavailable in it.

## Verified

- The owner's Mac library (264 meetings, 1,164 transcript passages, 73 summaries, 95 speakers, 3 folders, 16 people) uploaded as 283 records.
- An isolated empty library on the same Mac downloaded an identical copy: same counts and same content hashes, with zero voice embeddings.
- Its next scan found nothing to send back.

## CLI

`minutes-cli sync status|pending|payload <Kind:id>|reset [--recordings]` inspects what would sync. A command-line tool cannot hold the iCloud entitlement, so sending happens in the app.
