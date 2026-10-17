# Direct Google Calendar connection

Minutes now contains a direct Google Calendar read-only client, independent of Apple Calendar/EventKit. The connection uses fresh PKCE S256 and state for each sign-in; tokens live only in the platform Keychain. Normal reads refresh an expired access token, preserve rotated refresh tokens, and paginate within the requested time interval. Sign-out deletes local credentials and attempts Google's revoke endpoint. `--local-only` explicitly skips remote revocation.

Google project `minutes-511702` and both native clients were configured with the owner on October 14, 2026. Public IDs are wired into app metadata; registration is kept in Keychain, with no secrets in source or chat. Real native Mac authorization, token exchange, Keychain token save and initial events API readback passed. Expired-token refresh/restart acceptance and Google production verification remain pending; see the [current repair report](../../audit-2026-10-14/13-RECORDING-AND-GOOGLE.md). Synthetic tests exercise code exchange, state rejection, refresh/revocation, pagination and attendee mapping; they do not prove a configured Google account works.

## Owner setup

1. In the intended Google Cloud project, enable **Google Calendar API**.
2. Configure Google Auth Platform branding, audience, contact details and data access. Request only `https://www.googleapis.com/auth/calendar.events.readonly` and `https://www.googleapis.com/auth/calendar.calendarlist.readonly`. Both grants are required. Add the intended accounts as test users while using a testing audience. Follow Google's verification requirements before public distribution.
3. Create a **Desktop app** OAuth client for the Mac app/CLI. Supply its public client ID (ending `.apps.googleusercontent.com`). Minutes binds an OS-assigned port on `127.0.0.1`, opens the default system browser and receives the redirect at `http://127.0.0.1:<port>/`. This is an installed-app loopback redirect, unrelated to the future Minutes website.
4. Create a separate **iOS** OAuth client for the actual signed bundle identifier. Current generated development target uses `app.minutes.ios`; confirm the final identifier before creating credentials. Supply the iOS public client ID. Minutes uses `ASWebAuthenticationSession` and `<reversed-client-id>:/oauth2redirect`.
5. Set the public Xcode build setting `GOOGLE_REVERSED_CLIENT_ID` to that reversed client ID, e.g. `com.googleusercontent.apps.<public-id-prefix>`. `Apps/project.yml` registers this callback scheme. Regenerate the Xcode project after changing public build metadata. Apple Team ID/signing provisioning and any optional App Check setup remain owner inputs.
6. In Minutes Settings enter the platform's public client ID, then explicitly choose Connect Google Calendar. CLI uses the public JSON below. Select calendars by their IDs; default is `primary`. The `google calendars` command lists readable calendar IDs after connection.

Do not copy Google's full downloaded OAuth credential JSON into the public metadata fields. Public metadata still rejects secret-bearing keys. Some Desktop registrations require `client_secret` at Google's token endpoint (confirmed for this project); Minutes reads that optional desktop registration from a separate Keychain item and includes it only in code exchange and refresh. The iOS client never uses it. Installed-app registration secrets are extractable and are not a substitute for PKCE/state validation. The current owner registration is installed locally; distribution still needs an intentional registration provisioning path.

Keychain registration format: service `app.minutes.oauth.google-desktop-client`, account equal to the desktop public client ID, UTF-8 JSON with `clientID` and `clientSecret`. Shared code provides `GoogleDesktopClientRegistration.save(...)`. Do not pass a secret as a shell argument, commit it, log it or write it into app Info.plist. User access/refresh tokens use a different Keychain service and are removed independently on sign-out.

```json
{
  "desktopClientID": "<desktop-public-client-id>.apps.googleusercontent.com",
  "iOSClientID": "<ios-public-client-id>.apps.googleusercontent.com",
  "calendarIDs": ["primary"]
}
```

CLI:

```sh
minutes-cli google auth --config ./google-public.json
minutes-cli google status --config ./google-public.json
minutes-cli google calendars --config ./google-public.json
minutes-cli google events --config ./google-public.json --days 7 --json
minutes-cli google disconnect --config ./google-public.json
```

The Mac browser must run on the same Mac as the CLI's loopback listener. There is no deprecated out-of-band code-paste fallback for a headless remote shell. Authorization times out after five minutes. Reconnect after account authorization expires or is revoked; disconnect removes local credentials even if the remote revoke service is unreachable and reports that failure.

Cancelled events, all-day events and events without valid explicit timed starts/ends are omitted from the upcoming meeting list. Invitee response status remains an invitation response, not evidence that someone attended a recording. Selected calendar IDs are encoded as individual URL path segments. Recurrences retain occurrence-specific event IDs and start times.

## Primary documentation

- [Google native OAuth flow](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google OAuth policies](https://developers.google.com/identity/protocols/oauth2/policies)
- [Calendar events list and interval semantics](https://developers.google.com/workspace/calendar/api/v3/reference/events/list)
- [Calendar pagination](https://developers.google.com/workspace/calendar/api/guides/pagination)
