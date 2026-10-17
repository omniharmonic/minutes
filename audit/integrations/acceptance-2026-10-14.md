# Local HTTP acceptance — 2026-10-14

Command: `python3 minutes/audit/integrations/run-prism-contract.py`

Result: exit 0. Swift build completed in 11.12 seconds. The opt-in
`PrismHTTPContractTests.actualPrismCommitsInitialAndEditedRevisionsWithRestrictedGrant`
test passed in 0.105 seconds against the actual Prism app on an ephemeral
`127.0.0.1` HTTP port.

Verified restricted `minutes-native` capabilities for the primary synthetic
vault; first durable committed receipt; unchanged enqueue deduplication; edited
source revision with the prior server receipt's revision; second committed
receipt; actual import receipt GET; and generic `/api/notes` HTTP 403 with that
same restricted bearer.

Fixture shutdown reported four synthetic vault notes (two immutable revisions,
each with meeting and transcript). No production server, vault, device account,
or Keychain was used. Temporary synthetic bearer files were removed by the
runner. The fake-vault wrapper blocked external outbound network access.

Final-source rerun after authorization fixes: exit 0, build 7.16 seconds,
1 HTTP contract test passed in 0.068 seconds; shutdown again reported four
synthetic notes. Log: `audit-2026-10-14/notes-first-evidence/prism-http-contract-final.log`.
