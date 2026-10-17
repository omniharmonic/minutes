# Swift → Prism HTTP contract acceptance

Run from the `no_Saas` workspace root:

```sh
python3 minutes/audit/integrations/run-prism-contract.py
```

Requires the existing Swift toolchain, Node, and installed dependencies in
`integrations/prism-current/apps/server`. The runner starts the actual Prism
application with `.env.test`, an in-memory SQLite database, a fake in-memory
vault, and a synthetic restricted `minutes-native` grant. HTTP listens only on
an ephemeral `127.0.0.1` port; other outbound network requests are blocked.
Synthetic credentials use a temporary file with mode `0600` and an injected
memory credential store. The test never reads or writes Keychain.

The Swift test is disabled in normal `swift test` runs. The runner sets
`MINUTES_PRISM_CONTRACT_URL` and `MINUTES_PRISM_CONTRACT_TOKENFILE` only for its
child process and removes the files and stops the server on completion.

Acceptance covers actual URLSession HTTP requests through the real Prism
authorization and integration routes: restricted capabilities, durable initial
commit, unchanged enqueue reuse, edited revision with the first receipt's
precondition, receipt retrieval, and HTTP 403 for generic owner note access.
Only synthetic notes and transcripts reach the fake vault.
