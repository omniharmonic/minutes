# Native Prism connection contract (implemented; deployment pending)

> **Deployed staging (2026-10-14):** `https://minutes.omniharmonic.com` on the Mac mini now supports the restricted Minutes contract. The owner approved the isolated Minutes Staging vault, and native meeting export, unchanged deduplication, and an edited revision passed actual vault readback. See [deployment runbook](MAC_MINI_STAGING.md) and [acceptance evidence](../../audit-2026-10-14/12-MAC-MINI-DEPLOYMENT.md). Older statements below about undeployed infrastructure describe the prior baseline.

Minutes has a native, explicit sign-in client for a dedicated **minutes-native** device grant. It uses PKCE S256, one-attempt state and the exact callback `minutes://auth/callback` in the system authentication browser. The device credential is stored only in a per-origin Keychain item. This client never falls back to `prism-native`, owner-wide device tokens, personal access tokens or the legacy Parachute adapter.

The owner lifted the server-work pause after Prism stabilized at `288ce029`. Restricted server integration has been implemented against that revision and exercised by the native Swift client over isolated loopback HTTP; production deployment and real account authorization remain pending. `minutes.omniharmonic.com` is an intended product origin, not a verified running Prism integration service. A missing endpoint, unregistered client or missing restricted grant must produce a connection error. No live personal vault writes or account sign-ins were performed while testing this client.

## Server implementation and deployment prerequisites

The server now registers `minutes-native` with exact callback `minutes://auth/callback`, requires owner-selected consent for one vault, and centrally denies generic owner/admin/passthrough routes to its device tokens. Collaboration sockets and mixed bearer/cookie requests are also confined. The validated source is applied to the active Prism checkout; the running service has not been redeployed. See the server handoff at `integrations/prism-current/docs/minutes-integration.md`.

The existing native-auth protocol supplies:

- `GET /auth/device/authorize` with `response_type=code`, `client_id=minutes-native`, `redirect_uri`, `code_challenge`, `code_challenge_method=S256`, `state`, `label`.
- `POST /auth/device/token` form fields `grant_type=authorization_code`, `client_id`, `redirect_uri`, `code`, `code_verifier`. Expected credential: Bearer token in the existing `pd_…` device-token format.
- `POST /auth/device/revoke` form field `token`.

The implemented **Minutes v1 capability contract** is authenticated `GET /api/integrations/minutes/capabilities`:

```json
{
  "integration": "minutes",
  "clientId": "minutes-native",
  "restricted": true,
  "schemaVersions": [1],
  "operations": ["meetings:write", "imports:read"],
  "vaults": [{"id": "<granted-vault-id>", "name": "<display-name>"}]
}
```

The client fails closed if this declaration is missing, malformed, generic-owner, unrestricted, missing required operations, or has no destinations. The declaration is a compatibility check; the server also enforces the restricted grant centrally on every request. Synthetic server tests cover generic API/MCP/socket exclusion, wrong-vault requests and revocation, and the native Swift client has passed real loopback HTTP export/receipt acceptance.

The existing client upload contract remains `PUT /api/integrations/minutes/meetings/{sourceMeetingId}` with exact `X-Prism-Vault`, `Idempotency-Key` and versioned JSON. Later revisions require `If-Match` containing the quoted actual committed receipt revision; first imports omit it. The server preserves immutable revision note pairs and exposes device-bound receipts at `GET /api/integrations/minutes/imports/{importId}`. A 202 remains pending until a committed receipt is observed. No client method treats browser sign-in alone as permission to export.

## Native API

`PrismConnection(origin:store:credentialStore:session:)` validates and canonicalizes an HTTPS origin (HTTP allowed only on loopback for local development). `connect(using: OAuthSystemBrowserSession())` opens the browser explicitly, redeems the code, verifies capabilities and then saves the credential. A newly minted credential that fails capability verification is not saved; the client attempts to revoke it.

`status()` exposes saved-credential presence and in-memory verified capabilities, without returning tokens. On restart, `verifyCapabilities()` rechecks a saved connection before export. `disconnect()` deletes local credentials before remote revocation; a thrown network error means revocation was unconfirmed, not that local credentials remain connected.

`enqueue(bundle:destinationVault:)`, `outboxItems()`, `syncPending()`, `retryItem(id:)` and `cancelItem(id:)` support the native UI. New queued rows persist a canonical `destination_origin`. Workers process only rows belonging to their origin; unbound legacy rows are not silently assigned to a newly configured host. Changing a server never migrates queued personal meeting content. Local queue cancellation cannot undo a request already accepted remotely.

## Owner inputs still needed

- Review and deploy the validated server integration based on stable Prism `288ce029`.
- Explicit staging Prism origin and vault for acceptance testing.
- Real-account browser consent, wrong-vault/revoked-grant tests and an idempotent committed import against that staging server. These checks already pass locally with synthetic accounts/data, including native Swift HTTP acceptance.
- DNS/TLS and Mac mini service setup for the intended public product domain, plus approval of the concrete deployment after source review.

CLI uses the same Keychain-backed connection after native app sign-in:

```sh
minutes-cli prism status --origin https://<staging-prism-origin>
minutes-cli prism verify --origin https://<staging-prism-origin>
minutes-cli prism enqueue <meeting-id> --origin https://<staging-prism-origin> --vault <granted-vault-id>
minutes-cli prism outbox --origin https://<staging-prism-origin>
minutes-cli prism sync --origin https://<staging-prism-origin>
minutes-cli prism disconnect --origin https://<staging-prism-origin>
```

Queueing and sending are separate explicit commands. CLI browser sign-in is not provided for Prism's custom-scheme callback; the native app owns that callback. No `--token` option or plaintext credential file is accepted.

Queue identities also bind an opaque SHA-256 fingerprint of the device grant. The fingerprint cannot authenticate to Prism. A replacement token—even for the same server and vault—cannot send or retry rows from the previous grant. Existing rows remain visible and can be cancelled; exporting the original meeting again is an explicit requeue under the currently verified grant.

`enqueueNextRevision` performs read/decide/write under a SQLite immediate transaction. Unchanged payloads reuse their row and idempotency key. Edits cannot overtake a pending/unknown import. A later revision is created after a committed receipt, using that receipt's actual `serverRevision` as `If-Match`; source revision numbers are not server revision numbers. Conflict resolution requires an explicit known server revision through the API, rather than an automatic overwrite.
