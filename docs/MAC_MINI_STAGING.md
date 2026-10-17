# Minutes staging on the Mac mini

Deployed October 14, 2026, using the tested Prism integration on baseline `288ce029`. This is an isolated staging instance, not the personal Prism instance.

| Item | Value |
|---|---|
| HTTPS origin | `https://minutes.omniharmonic.com` |
| Server bind | `127.0.0.1:8789` on the Mac mini |
| Vault | `minutes-staging-20261014` |
| Grant registry ID / label | `minutes-staging` / Minutes Staging |
| Release | `~/dev/minutes-prism-staging/releases/20261014-288ce029-minutes1` |
| Current symlink | `~/dev/minutes-prism-staging/current` |
| Server process | PM2 `minutes-prism-staging` |
| Tunnel process | PM2 `minutes-prism-tunnel` |
| Tunnel | `minutes-prism-staging` (`bf77975f-f9c2-4698-9541-e980b1841d06`) |
| Database | `~/dev/minutes-prism-staging/data/prism-server.db` |

The staging `.env` holds fresh session/capability secrets and a token scoped only to `vault:minutes-staging-20261014:write`. It uses the existing transactional email sender and owner identity for real sign-in. The vault token expires **2026-11-14 00:33:56 UTC** (November 13 in Denver); renew it on the host before then. Keep all tokens in private host files, never source control, chat or native app settings. The app receives its own selected-vault device grant instead.

Creating this vault did not change the default vault. Main Prism's server, database, source checkout and tunnel were not restarted or replaced. The staging server uses the installed dependency tree only after matching package-lock hashes, and serves the current stable web build; server source is snapshotted separately. Its deployed source hashes match the tested integration.

## Service operations

On the Mac mini, with `/opt/homebrew/bin` on PATH:

```sh
pm2 describe minutes-prism-staging
pm2 describe minutes-prism-tunnel
pm2 restart minutes-prism-staging
pm2 save
```

To stop this staging deployment, stop **only these two named processes**. The domain will then stop serving staging; keep the vault/database for diagnosis. Never stop `prism-server`, `prism-tunnel` or Parachute as part of staging maintenance. DNS points the Minutes hostname to its own tunnel and does not modify the existing Prism route.

Use SQLite's backup API for the staging DB before a future release. Create a new release directory, verify source/dependency hashes, update `current`, then restart the staging server. Do not overwrite existing secrets or copy production's database. Keep logs private; do not enable logging of authorization headers or full callback URLs.

## Acceptance

Public TLS passed. `/` returns 200; signed-out `/auth/me` and the Minutes capabilities route return 401. The port listens only on loopback, and the scoped vault API returns 200.

Real Safari email sign-in, owner approval for Minutes Staging, persisted native Keychain credentials and native capability verification passed. The native Share → Send to Parachute flow committed a synthetic meeting. Actual vault readback verified the meeting, transcript and link. An unchanged repeat created no duplicate; an edited note committed revision 2 while keeping revision 1 intact. [Receipts and detailed evidence](../../audit-2026-10-14/12-MAC-MINI-DEPLOYMENT.md).

A live callback queue-isolation crash was fixed and regression-tested. After relaunch, use **Verify Connection** to restore the already-saved grant. Browser email sign-in must occur in Safari for the native session to see it. Automatic restoration, cancellation and browser guidance were subsequently implemented. Final installed build 8 restored its restricted connection and exported another synthetic meeting with a committed revision-1 receipt. Actual microphone/system capture and Google OAuth acceptance are documented in the [extended recording report](../../audit-2026-10-14/15-EXTENDED-CAPTURE-AND-NATIVE-REFINEMENT.md).
