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

**Before recording (5 minutes, not filmed):**
- On the Mac, update Minutes to build 70 (Minutes → Check for Updates).
- In Google Calendar on the web, create a calendar named **Minutes Demo** (Other calendars → + → Create new calendar).
  - Add two events to it in the next few days: "Weekly planning" and "Design review".
  - Give each one a Google Meet link (Add Google Meet video conferencing) and one or two of your own addresses as guests.
  - With this calendar, the video never shows real meetings or other people's addresses.
- In Minutes → Settings → Calendar, choose **Disconnect**, so the take starts from the consent screen.
- In Dia, stay signed in to synergy@benjaminlife.one. A password prompt during the take is fine, but don't show any two-factor codes.
- Quit or hide Messages, Signal, WhatsApp and Telegram, and turn on Do Not Disturb.
- Open these Dia tabs in order:
  1. https://minutes.omniharmonic.com/about
  2. https://minutes.omniharmonic.com/privacy (scroll to "Google user data")
  3. Google Calendar, showing the Minutes Demo event
  4. https://myaccount.google.com/connections

**Recording the Mac part:**
- Press **⇧⌘5 → Record Entire Screen → Record**.
- Make it **one continuous take with no edits**. Go slowly: hold each screen for about 3 seconds.
- Silent is fine. You can narrate if you like.

**Script (about 4 minutes):**

1. Show the About tab, then scroll the Google section of Privacy.
2. Switch to Minutes → Settings → Calendar → Google Calendar → **Connect Google**.
3. In the browser:
   - choose synergy@benjaminlife.one;
   - on the consent screen, pause on the two read-only permissions ("See your calendar list" and "View events on all your calendars");
   - click **Continue / Allow**.
4. Back in Minutes it says **Connected**, and the calendar list appears. This shows *calendarlist.readonly*.
   - Untick every calendar except **Minutes Demo**.
5. Open **Upcoming**. The two demo events appear. This shows *events.readonly*.
   - Click "Weekly planning" and pause on its title, time, Meet link, organizer, guests and their RSVP status.
6. Click **Record** on that event and speak a sentence. Stop after about 10 seconds.
   - The new meeting is named after the event.
   - Open it, then **Speakers**: the guests are offered as names for the speaker.
7. Switch to the Google Calendar tab and refresh. The event is unchanged.
   - Say or show that Minutes has no create, edit or delete actions.
8. Minutes → Settings → Calendar → **Disconnect**.
   - Switch to the Google Account connections tab and refresh: Minutes is no longer listed.
9. Stop the recording with the ⏹ button in the menu bar. The file is saved to the Desktop.

**Recording the iPhone part (a second short take):**
- On the phone, open Control Center → **Screen Recording**.
- In Minutes, go to Settings → **Connect Google**: choose the account → consent screen (pause) → Allow.
- The calendar list appears: tick **Minutes Demo** only.
- Open **Upcoming** and tap "Weekly planning" to show its details.
- Stop the recording and AirDrop it to the Mac.

**After recording:**
- In YouTube Studio, choose Create → Upload videos for each file. Set Visibility to **Unlisted**, with titles "Minutes for Mac – Google Calendar OAuth demo" and "Minutes for iPhone – Google Calendar OAuth demo".
- In Google Cloud Console (project minutes-511702) → Google Auth Platform → **Data Access**:
  - paste the Mac link in the demo video field (add the iPhone link to the justification text);
  - paste the scope justification from section 2;
  - Save.
- Under **Verification Center**, use **Prepare for verification** / **Submit**, if Google offers it.
- Send the reply in section 4, replacing the placeholder with both links.
- Under **Audience**, check the publishing status:
  - **In production**: friends can sign in now, but see "Google hasn't verified this app" (Advanced → Go to Minutes) until approval.
  - **Testing**: only listed test users can sign in. Add your friends' Google addresses there, or choose Publish app.

## 4. Reply to Google (send after the video link is saved)

> Hello,
>
> Thank you for the review of project 618880165655 (minutes-511702). We have addressed each item:
>
> 1. **Privacy policy:** https://minutes.omniharmonic.com/privacy (effective October 20, 2026) now states:
>    - how Minutes uses Google user data (each scope, the data read and the features that use it);
>    - with whom it is shared, transferred or disclosed (no one, beyond Google's own API and destinations the user explicitly chooses);
>    - the protection mechanisms for that data (OAuth with PKCE, tokens only in the device Keychain, TLS, read-only access, on-device storage protected by the operating system, revocation on disconnect).
> 2. **Demo video:** new live, uninterrupted recordings: Mac client [MAC VIDEO LINK], iOS client [IPHONE VIDEO LINK]. They show:
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
