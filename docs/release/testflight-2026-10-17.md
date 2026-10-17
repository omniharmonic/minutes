# iOS TestFlight preparation — 2026-10-17

Release identity: Minutes 1.0.0 (41), bundle `app.minutes.ios`, Apple team `83Y42N33H8`. Minimum iOS 18.0; iPhone and iPad supported. This report records local preparation separately from App Store Connect processing and an installation through TestFlight.

## Reproduce

From the repository root, run `./scripts/archive-ios.sh` to regenerate the pinned XcodeGen project, create a generic iOS Release archive, and validate its packaged metadata/resources/signature. `./scripts/archive-ios.sh --export` additionally exports an App Store Connect IPA locally using the existing Xcode account and automatic signing. Neither command uploads. The script refuses to overwrite an existing archive; preserve/move that artifact before rebuilding. To export an existing archive after provisioning is ready:

```sh
xcodebuild -exportArchive \
  -archivePath build/Minutes-iOS-41.xcarchive \
  -exportPath build/TestFlight41 \
  -exportOptionsPlist scripts/ExportOptions-TestFlight.plist \
  -allowProvisioningUpdates
```

Output paths: `build/Minutes-iOS-41.xcarchive`, optional `build/TestFlight41/`. Local build log: `/private/tmp/minutes-ios41-archive.log`. Xcode needs access to its existing caches, signing identities, account and provisioning profiles outside the repository; a sandbox-only invocation failed on its SourcePackages cache before compiling.

## Packaging checks

The archive script checks concrete version/identity, microphone/Speech/Calendar purpose strings, background `audio`, iOS deployment target/device family, default ATS without arbitrary loads, compiled icon catalog and primary AppIcon entry, no-tracking privacy manifest and FluidAudio resource bundle. It then verifies the complete application code signature. Required device capabilities are reported from the packaged Info.plist rather than adding unnecessary hardware restrictions. These checks do not exercise recording or playback.

The committed AppIcon is an opaque 1024×1024 universal iOS source. `Apps/Shared/PrivacyInfo.xcprivacy` declares app-owned preferences and permitted file metadata use with no tracking. Store privacy answers and final third-party privacy reports require review against the app's optional user-configured exports/calendar services; a local manifest is not store approval.

## Export encryption declaration

`ITSAppUsesNonExemptEncryption` is `false` in the XcodeGen source and generated iOS Info.plist. Current source uses OS URLSession HTTPS, system Keychain storage, OS Data Protection, and CryptoKit hashes for PKCE, model integrity and stable identifiers. No custom/proprietary encryption implementation was found. The pinned FluidAudio 0.17.7 Swift package uses URLSession downloads and CryptoKit SHA256/SHA1 integrity hashes; its native helpers are audio/clustering/text processing, not bundled cryptographic transports. Reassess this declaration if cryptography or dependencies change.

Apple documents that OS encryption, including URLSession HTTPS, is typically exempt from documentation upload requirements, and that the false value covers no encryption or exempt encryption including linked libraries: [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations), [ITSAppUsesNonExemptEncryption](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption). This technical inventory supports the declaration; no export compliance approval is implied.

## Actual result

`xcodebuild archive` succeeded. The archive is arm64, 1.0.0 (41), with `UIRequiredDeviceCapabilities = [arm64]` and all scripted checks passing. Code-signing verification reports valid on disk and satisfies its designated requirement. Its existing signing identity is Apple Development for the intended team; public entitlement inspection confirms `83Y42N33H8.app.minutes.ios`, team `83Y42N33H8`, and development `get-task-allow = true`. Export must re-sign for App Store distribution.

The local App Store Connect export failed with exit 70 and both concrete errors:

- `exportArchive No Accounts` — Xcode asks for an account in Accounts settings.
- `exportArchive No profiles for 'app.minutes.ios' were found` — no matching iOS App Store provisioning profile.

An unrestricted public signing-identity read found Apple Development and Developer ID Application certificates only, with no Apple Distribution identity. An already signed-in browser account is insufficient for Xcode automatic distribution signing. Restore/sign in to the intended Apple Developer account in Xcode and make its existing distribution signing setup available, then retry the export command above. No distribution credentials or profiles were guessed or manually created in this pass.

No IPA, App Store Connect upload, processing, tester availability or physical TestFlight install was established by the packaging step. Developer ID for Mac cannot replace iOS App Store distribution signing. No private keys, agreements or store metadata were created by this step. No recording or playback occurred.

## Owner account restored and upload completed

After the owner signed Xcode into team83Y42N33H8, the fresh build41 archive exported successfully with App Store automatic signing. The explicit App ID app.minutes.ios and App Store Connect record6823896660 were created; the available store name is **Minutes by Omniharmonic**. Xcode upload completed successfully; Apple finished processing it. Local logs: `/private/tmp/minutes-ios41-account-export.log`, `/private/tmp/minutes-testflight41-upload.log`.

Beta description, contact details (kept only in App Store Connect), privacy URL and review notes are saved. No app account is required for local recording/processing. The Minutes Public Beta group has build1.0.0(41), submitted with test instructions; observed status **Waiting for Review**. The owner explicitly approved its public invitation with a 100-tester cap: https://testflight.apple.com/join/jWJ68SJV . Apple currently states testers cannot join until the group has an approved build. Neither public availability nor an actual TestFlight installation is claimed yet. The subsequent transcript-find changes are not in build41.
