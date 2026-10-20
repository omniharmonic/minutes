# Owner setup and production acceptance

Updated 2026-10-14. This checklist records real inputs that cannot be replaced by a successful local build.

## Google Calendar

Provide public configuration only:

- Google Cloud project ID with Calendar API enabled.
- Desktop OAuth client ID for Mac/CLI.
- iOS OAuth client ID registered to the signed iOS bundle (`app.minutes.ios` in the current project).
- Test-account emails added to the Google Auth Platform audience while in Testing.

Configure branding/support contacts and the two read-only Calendar scopes (`calendar.events.readonly` and `calendar.calendarlist.readonly`). For release, satisfy the live Google console's consent/verification requirements and provide privacy/support URLs. See [exact setup](GOOGLE_CALENDAR_SETUP.md). Do not paste refresh tokens, passwords or a downloaded client-secret file into chat. The native flow uses system-browser PKCE, not a web OAuth client for the Minutes website.

## Apple distribution

Provide/confirm:

- Apple Developer Team ID and final Mac/iOS bundle identifiers.
- A Developer ID Application signing certificate **with its private key already installed in the build Mac's Keychain**. Supply the identity's name to `DEVELOPER_ID_APPLICATION`; do not send the private key.
- A local notarytool Keychain profile name in `NOTARYTOOL_PROFILE`, configured through your Apple account or App Store Connect API key. Keep account credentials/API private keys in secure local storage.
- iOS App ID/provisioning and App Store Connect record for TestFlight/App Store delivery. Sign in to Xcode on the intended build host so automatic signing can provision the native target.

### Set up Developer ID on the build Mac

1. Use an active paid Apple Developer Program team. In Xcode → Settings → Apple Accounts, sign in yourself and select the team. Account passwords and two-factor codes belong only in Apple/Xcode dialogs.
2. Open Manage Certificates, press + and choose **Developer ID Application**. The Account Holder creates this certificate. Keep the generated private key in this Mac's login Keychain. A downloaded certificate alone cannot sign without its matching private key. Do not revoke an existing working certificate to create another.
3. Find the public Team ID in Apple Developer account membership details. Keep the existing Mac bundle identity `ai.nosaas.minutes` for this app so upgrades retain their identity; iOS currently uses `app.minutes.ios` and its separate native Google registration.
4. At account.apple.com → Sign-In and Security → App-Specific Passwords, create a password for notarization. Run the following **yourself** in Terminal and answer the interactive Apple ID, Team ID and secure password prompts:

   ```sh
   xcrun notarytool store-credentials Minutes-Notary
   ```

   The CLI validates the credentials with Apple and saves them in Keychain. Do not put the password in command arguments, source, environment files or chat. An App Store Connect API-key Keychain profile is an alternative if you already manage one; it is not required for this path.
5. Tell the agent only the public Team ID, the certificate identity name (or say it is ready for local discovery), and that Keychain profile `Minutes-Notary` is ready. Never upload a private-key/P12 file to chat. The certificate and credentials must exist on the actual packaging Mac; installing them only on another Mac does not provision this machine.

The agent can verify `security find-identity -v -p codesigning`, sign with hardened runtime and secure timestamp, submit the app archive to Apple's notary service, require Accepted, staple the ticket, and run Gatekeeper checks. Notarization sends the signed application to Apple; it does not upload meeting recordings, calendar grants or the local database. A successful signed local build is still not physical-device or App Store acceptance.

References: [Apple Developer ID creation](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

Mac package command:

```sh
DEVELOPER_ID_APPLICATION='Developer ID Application: BENJAMIN GLEASON ROSS (83Y42N33H8)' \
NOTARYTOOL_PROFILE=minutes-notary MINUTES_BUNDLE_GOOGLE_REGISTRATION=1 ./scripts/build-app.sh
```

The script refuses a Developer ID build unless it is either notarized (`NOTARYTOOL_PROFILE`) or marked as local-only (`MINUTES_ALLOW_UNNOTARIZED=1`). A notarized build must also bundle the Google registration. When `build/signing/Minutes_DeveloperID.provisionprofile` exists, iCloud sync is included automatically; see docs/SYNC_SETUP.md. Any CloudKit schema change must be deployed to Production (`docs/cloudkit-schema.ckdb`, `xcrun cktool import-schema`, then Deploy in CloudKit Console) **before** a build that uses it ships, because every build talks to Production.

The script signs nested resources and the app, submits to notarization only when explicitly configured, checks Accepted status, staples/validates and assesses Gatekeeper before publishing a notarized ZIP. An ad-hoc build is local-test-only. A signed archive without a notary profile remains explicitly unnotarized.

iOS: regenerate `Apps/Minutes.xcodeproj` from `Apps/project.yml`, set `DEVELOPMENT_TEAM` and the public `GOOGLE_REVERSED_CLIENT_ID`, archive, then distribute through App Store Connect/TestFlight. No upload or App Store submission has occurred in this pass.

## Hardware acceptance

On the signed Mac build, explicitly allow Microphone and Screen & System Audio Recording in Privacy & Security. Restart only if macOS requests it. Choose **Mac call audio + microphone** in Record & Import. In a controlled session with headphones and no private content playing, record a short test from two machines, then check both original CAF tracks, the timestamp manifest, mixed audio, and transcript. Repeat for route changes, sleep/interruption, permission revocation and a long meeting. Synthetic timing tests do not replace this.

On a physical iPhone: grant microphone and on-device Speech permissions, install speaker models explicitly, test foreground and screen-locked recording, interruptions, low storage, stop/process, transcript correction and export. Benchmark accuracy, runtime, battery and thermal behavior before making automatic-identity or long-session performance claims.

## Prism and Mac mini

The owner lifted the server-work pause after Prism stabilized at `288ce029`. Restricted Minutes server routes, selected-vault grants and idempotent imports are deployed in isolated Mac mini staging; native consent, committed imports and revision readback passed. Staging origin: `https://minutes.omniharmonic.com`. Owner authorized creation of a new isolated test vault; no live personal vault should be used as a test fixture.

Remaining acceptance: test wrong-vault access, revoked devices/grants, duplicate uploads, lost responses, revision conflicts and server restarts. The client must not display Connected/Synced for a missing capability route or an HTTP202 pending receipt. See [pending server contract](PRISM_CONNECTION_SETUP.md).

StudioLink needs a separate real two-machine Tailscale recording/upload/export test. Its host helper must run on the recording host, with a reachable HTTPS guest URL and provisioned FFmpeg/ffprobe; a website-only deployment does not run its local host/media pipeline.

## Privacy manifest and submission review

`Apps/Shared/PrivacyInfo.xcprivacy` is included in the generated iOS target and Mac package. It declares app-owned preferences (CA92.1) and metadata of app-owned/user-selected files (C617.1/3B52.1), with no tracking. Review the final archive's third-party SDK privacy report and App Store privacy answers against the shipped behavior; this declaration alone does not establish store approval. [Apple required-reason documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).

## App icon sources

The original geometric waveform icon is generated by `swift scripts/render-app-icon.swift "$PWD"`, followed by `iconutil -c icns build/Minutes.iconset -o Apps/Shared/Minutes.icns` on a Mac. The committed iOS source is an opaque 1024×1024 RGB PNG; the Mac ICNS uses transparent rounded corners. The generated native target selects the AppIcon catalog.

## Installed Mac signing setup (2026-10-14)

The owner-created Developer ID Application identity for team `83Y42N33H8` is installed in login Keychain; the notarization credential profile is `Minutes-Notary`. Build6 was accepted by Apple, stapled, and passed Gatekeeper assessment as a notarized Developer ID app. No further Mac signing password or credential needs to be sent through chat. Subsequent releases must use this same identity/profile via `DEVELOPER_ID_APPLICATION` and `NOTARYTOOL_PROFILE`; do not ad-hoc re-sign the installed app. App-specific passwords remain in Keychain. Physical iPhone provisioning, App Store submission and clean-device acceptance are separate release steps.


### Silent system-audio acceptance

Use **Mac audio only** when testing device capture without recording the room. The native recording card must say microphone off; validate the finalized `capture.json` contains only `system` and that no microphone files exist. Successful system capture is not established by nonempty mixed audio alone: compare the system signal and transcript against a known fixture and separately verify automatic completion.

The owner requested silent testing while with a group on October 16. Do not resume audible synthetic playback or microphone capture without fresh readiness. Prefer a test player explicitly bound to an installed virtual output such as BlackHole (AVAudioPlayer.currentDevice), with fail-closed device verification and no default-output change. This passed native ScreenCaptureKit capture on this Mac. If testing via hardware mute instead, verify mute before playing and stop the stimulus if mute or output route changes. CoreAudio numeric device IDs can change; store a stable device UID when restoring mute. Keep generated playback and room capture separate. Stop playback before restoring the previous mute state. A six-minute generated fixture is available in the current temporary test environment, but is not a dependency of release code or model-free tests.

Build 37 Developer ID package: `build/notes-shell-build37/Minutes-1.0.0-notarized.zip`. Its Apple acceptance receipt, stapled ticket and local Gatekeeper assessment pass. A clean unrelated Mac installation and App Store release remain separate acceptance gates.


## October 17 preview distribution

Mac build40 is the signed/notarized preview release candidate. Public installer repository: https://github.com/omniharmonic/minutes-studiolink-downloads ; application sources remain private. New Mac users should use Apple Calendar: Desktop Google registration provisioning and public Google audience/verification are deliberately not claimed complete. Owner Keychain registration/tokens are excluded from all artifacts. Existing configured installations retain them.

iOS40 remains a paired-device development install. Do not publish its development IPA as a universally installable download. Public iPhone distribution needs App Store Connect app record, distribution/archive validation and TestFlight/App Review; Developer ID notarization only covers the Mac app.
