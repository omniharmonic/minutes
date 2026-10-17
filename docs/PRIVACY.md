# Minutes privacy behavior

This document describes the current implementation, not a published legal policy or a claim of App Store approval.

- Recording begins after an explicit action. Mac call recording requires Screen & System Audio Recording and microphone permissions; the implementation saves audio, not screen images. iPhone recording uses its microphone.
- Audio and speaker embeddings are processed locally. Apple Speech is required to use on-device recognition; unsupported configurations report an error instead of enabling cloud recognition. Speaker model installation is an explicit download action.
- Optional Apple Foundation Models summaries use the on-device system model on eligible systems. Extractive notes remain a separate explicit choice. This app does not configure a cloud summary provider automatically.
- Google Calendar authorization opens the system browser. Access/refresh credentials are stored in Keychain. Only public client configuration is saved in preferences. Calendar invitees are candidate context, not proof that a person spoke or consented to a remembered voice.
- Speaker identity requires review. Saving a remembered voice is a separate opt-in action; remembered profiles can be removed. Ordinary exports do not include voiceprints or raw audio.
- Prism delivery sends the selected meeting's notes, transcript and participant context to the configured, verified destination. A browser sign-in alone does not establish a restricted grant or a successful import. Delivery remains queued until a committed receipt is verified.
- Changing a server or authorization must not silently redirect queued content. Disconnect preserves local meetings. Cancelling a local delivery cannot undo a request already accepted by a remote service.
- The app has no analytics or advertising SDK. No automatic retention/deletion schedule is currently promised. Audio, local records, explicit exports and remote copies require their respective deletion/retention controls; these controls are not yet a complete lifecycle product.

Before public distribution, publish an owner-approved privacy/support page at the production domain, audit the final archive/SDK privacy report and complete the Google and Apple disclosure flows for the actual shipped features.
