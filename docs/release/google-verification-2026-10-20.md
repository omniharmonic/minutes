# Google verification resubmission (2026-10-20)

Google's review of project 618880165655 (minutes-511702) raised three issues:
- The privacy policy lacked disclosures on data use, data sharing and data protection.
- The demo was edited still frames. Google requires a live, uninterrupted recording.
- The demo didn't show `calendar.events.readonly` doing its job.

## 1. Privacy policy (done)

https://minutes.omniharmonic.com/privacy (effective October 20, 2026) now has these sections under "Google user data":

- **How Minutes uses it:** a table of each scope, the fields read and the features that use them, plus the Limited Use and AI/ML statements.
- **With whom Google user data is shared, transferred or disclosed:**
  - The developer receives nothing.
  - Google receives the API requests.
  - When the user turns on sync, data goes to the user's own private iCloud.
  - When the user exports, data goes to the destination they choose.
  - No other transfers.
- **How Google user data is protected:** OAuth with PKCE, Keychain-only tokens, TLS, read-only scope, device file protection and encryption, iCloud encryption, and voice profiles never leaving the device.
- **Removing access:** Disconnect revokes the token; Google Account connections is linked.

In Cloud Console → Google Auth Platform → Branding, the privacy policy URL is unchanged; the content behind it was updated.

## 2. Scope justification (paste into Data Access → scope justification)

> **calendar.calendarlist.readonly:** Minutes shows the user's calendar list by name in Settings → Calendar so they can choose which calendars appear in Upcoming. Only calendar names and identifiers are read.
>
> **calendar.events.readonly:** Upcoming lists events from the chosen calendars for the next week. For each event it shows the title, time, conference link, organizer, and invitees with their RSVP status. From an event the user can:
> - start a recording that is named after the event and linked to it;
> - get a reminder before it begins;
> - link an earlier recording to the event that overlapped it.
>
> Invitee names are then offered as choices when the user labels who spoke in the transcript.
>
> **Why narrower scopes don't work:**
> - Free/busy scopes have no titles, conference links or attendees, so the app couldn't name recordings, identify the meeting or offer invitees.
> - `calendar.events.owned.readonly` excludes shared team calendars that users subscribe to, and choosing those is a core feature.
> - Minutes never writes, so no write scope is requested.
>
> **Data handling:**
> - All data stays on the user's device; Minutes has no server.
> - Tokens are stored in the system Keychain.
> - Disconnect revokes access.
> - Data is used only for these user-facing features, never for advertising, sale or AI/ML training, in line with the Google API Services User Data Policy, including Limited Use.

## 3. Demo video (owner records)

**Before recording:**
- Install the current builds (Mac 64+, iOS 60+).
- Use a Google account that holds no private data, ideally a dedicated demo account. Give it a second calendar named "Team".
- Create 2–3 events in the coming days on both calendars, with a Meet link and two invitees (they can be addresses you own).
- In Minutes on the Mac, choose Disconnect so the consent screen appears from the start.
- Close unrelated windows and turn on Do Not Disturb.

**Recording:**
- Use macOS screen recording (⇧⌘5 → Record Entire Screen) in **one continuous take with no edits**.
- Silent video is fine. Talk over it, or add a live caption by typing in a TextEdit window if you prefer.
- If a password or two-factor step is needed, sign in to the demo account in the browser **before** recording, so the take shows only account selection and consent.

**Script (about 4 minutes):**

1. Show https://minutes.omniharmonic.com/about, then the Google section of /privacy.
2. **Mac client:** open Minutes → Settings → Calendar → Google Calendar → **Connect Google**.
   - In the browser, choose the demo account. On the consent screen, hold for 3 seconds on the two read-only permissions ("See your calendar list"; "View events on all your calendars"), then **Allow**.
3. Back in Minutes it shows **Connected**. The new **calendar list** appears with the calendar names ← *calendarlist.readonly*. Tick **Team** next to the main calendar.
4. Open **Upcoming**. Events from both calendars appear ← *events.readonly*. Click an event to show its title, time, Meet link, organizer, invitees and their RSVP.
5. Show what the event data does:
   - Click **Record** on that event. The recording is named after the event; stop it after a few seconds.
   - Open the recording. Its invitees appear, and in **Speakers** they are offered as names to choose for a speaker. (Optionally show the reminder notification.)
6. **Show that nothing was written:**
   - Open the same event in Google Calendar on the web; it is unchanged.
   - Note that Minutes has no create, edit or delete actions.
7. **Disconnect:**
   - Minutes → Settings → Calendar → **Disconnect**.
   - Open https://myaccount.google.com/connections; Minutes is no longer listed. This shows the source-account effect of revocation.
8. **iOS client** (same take; the iOS Simulator or iPhone Mirroring are both fine):
   - Minutes for iPhone → Settings → **Connect Google** → consent screen → Allow.
   - The calendar list appears; tick Team.
   - Upcoming → an event's details.

**After recording:**
- Upload to YouTube as **Unlisted**.
- Paste the link in Data Access → Demo video, and save.

## 4. Reply to Google (send after the video link is saved)

> Hello,
>
> Thank you for the review of project 618880165655 (minutes-511702). We have addressed each item:
>
> 1. **Privacy policy:** https://minutes.omniharmonic.com/privacy (effective October 20, 2026) now states:
>    - how Minutes uses Google user data (each scope, the data read and the features that use it);
>    - with whom it is shared, transferred or disclosed (no one, beyond Google's own API and destinations the user explicitly chooses);
>    - the protection mechanisms for that data (OAuth with PKCE, tokens only in the device Keychain, TLS, read-only access, on-device storage protected by the operating system, revocation on disconnect).
> 2. **Demo video:** a new live, uninterrupted recording is linked in the Cloud Console: [UNLISTED YOUTUBE LINK]. It shows:
>    - the full OAuth consent flow for both the macOS and iOS clients;
>    - the calendar list (calendar.calendarlist.readonly) used to choose calendars;
>    - every user-facing feature of calendar.events.readonly: upcoming meetings with titles, times, conference links and invitees, starting a recording named after the event, linking invitees to the meeting and offering them when labelling speakers, and reminders.
>
>    Both scopes are read-only, so nothing in the user's account changes. The video also shows the event unchanged in Google Calendar, and access removed from the Google Account after Disconnect.
> 3. The scope justification in the Cloud Console explains why narrower scopes (free/busy, owned-calendars-only) cannot support these features.
>
> Kind regards,
> Benjamin Gleason Ross

Don't send the reply until the real link is in the Console. Never enter a placeholder link.
