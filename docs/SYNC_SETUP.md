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

## One-time Apple Developer setup (team 83Y42N33H8)

1. **Certificates, Identifiers & Profiles → Identifiers → iCloud Containers →** add `iCloud.ai.nosaas.minutes`.
2. **Identifiers → App IDs:** for both `app.minutes.ios` (iOS) and `ai.nosaas.minutes` (Mac), enable **iCloud**, choose **CloudKit**, and assign the container.
3. **Profiles:**
   - Create a **Developer ID** profile for `ai.nosaas.minutes` and download it, e.g. to `~/Downloads/Minutes_DeveloperID.provisionprofile`.
   - iOS uses automatic signing. Either sign in to Xcode → Settings → Accounts, or create an iOS development profile for `app.minutes.ios` that includes iCloud.
4. **CloudKit Console:**
   - Run one sync from a development build so the record types (`Meeting`, `Folder`, `Person`, `Audio`, each with `payload` and `schema` fields, and `audio` on Audio) are created.
   - Then **Deploy Schema Changes to Production**. Developer ID and TestFlight builds use the Production environment.

## Building with sync

```sh
# Mac (Developer ID + profile):
MINUTES_CLOUDKIT_PROFILE=~/Downloads/Minutes_DeveloperID.provisionprofile \
DEVELOPER_ID_APPLICATION="Developer ID Application: BENJAMIN GLEASON ROSS (83Y42N33H8)" \
MINUTES_BUNDLE_GOOGLE_REGISTRATION=1 ./scripts/build-app.sh

# iOS:
MINUTES_CLOUDKIT=1 Apps/generate-project.sh   # adds the entitlement + MinutesCloudKitContainer
```

Without these, builds behave as before, and Settings explains that sync isn't included in the build. The app only creates a CloudKit container when the build's Info.plist names one (`MinutesCloudKitContainer`), because CloudKit crashes in an app that lacks the entitlement.

## CLI

`minutes-cli sync status|pending|payload <Kind:id>|reset [--recordings]` inspects what would sync. A command-line tool cannot hold the iCloud entitlement, so sending happens in the app.
