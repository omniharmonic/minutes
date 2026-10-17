# Google Calendar verification demo

Preparation status 2026-10-17: owner will upload an unlisted YouTube video. The combined artifact is `build/GoogleVerification/Minutes-Google-Calendar-Demo.mp4` (97 seconds, 1920×1080 H.264, no audio stream). Genuine Mac and iOS connection, unverified-warning, read-only permissions, successful return and populated Upcoming frames are captured. The iOS portion uses the actual native client in an explicitly labelled iPhone simulator because physical iPhone Mirroring failed. The owner entered credentials and advanced both safety warnings; no password/2FA entry is included. An authorization that expired during preparation is excluded. Continuous desktop video capture failed, so the artifact clearly identifies itself as edited still-frame captures. Browser sidebar, account identity and private event titles/attendees were cropped or redacted and the output frames visually inspected. Google may still request continuous footage; no acceptance or scope verification is claimed. Never substitute a mock consent screen or a fabricated calendar/API result.

## Owner upload

Upload the combined MP4 to YouTube as **Unlisted**, with a title such as **Minutes — Google Calendar OAuth verification (macOS and iOS)**. Return its watch URL so the actual link can be saved with the Calendar scope justification. Do not upload raw screenshots or temporary capture files: those include unredacted private information. The edited MP4 contains no audio track, authorization URLs, callback codes or tokens.

## Required footage

A silent screen recording is sufficient; use on-screen captions to explain actions. Exclude passwords, authorization URLs/codes, tokens, private calendar event details and unrelated app windows. Pause capture during password/2FA entry. Do not record microphone, room sound or system playback.

1. Identify Minutes and project minutes-511702. Public home and privacy pages: https://minutes.omniharmonic.com/about and https://minutes.omniharmonic.com/privacy .
2. Mac: open Minutes Settings → Calendar → Google Calendar → Connect. Capture the real system-browser authorization, account choice, unverified-app warning if present, and the two read-only Calendar permissions. Do not bypass or grant consent without the owner's approval. Cut token-bearing loopback callback URLs from footage.
3. Return to Minutes, show Connected, selected calendars and Upcoming populated by the real API. Use a non-private test calendar; otherwise redact private names/addresses/titles before sharing. Show an event's time, call link and attendee context, and explain that Calendar RSVP does not identify a voice or prove attendance. No recording is needed.
4. iPhone: capture the same real native Connect → consent → return-to-app → Upcoming flow, including the iOS public client. iPhone Mirroring must be unlocked by the owner. The app is microphone-only on iPhone; no claim of other-app audio capture belongs in this demo.
5. Explain minimal scopes: calendar list selection and read-only event metadata; no calendar editing, Gmail or Contacts access. State that tokens remain in Keychain and normal recording works without Google or a server.
6. End with Disconnect being available. Do not revoke or delete the owner's saved grants merely to obtain footage.

Google's verification form requires a YouTube link and footage covering all OAuth clients assigned to this project. After upload, save the actual unlisted URL with the scope justification and submit the review. No placeholder video link should be entered.

## Current review status

Brand/domain verified and published; External audience In production. Calendar event sensitive scope remains unverified with a 100-user lifetime cap until approved. Written justification is prepared in the Google form; the required video is missing. A fresh-Mac bundle bootstrap passed using the actual notarized artifact with an empty in-memory credential store and mock token transport; this is not a replacement for the real consent footage.
