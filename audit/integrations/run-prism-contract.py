#!/usr/bin/env python3
"""Run the Swift client against actual Prism routes over ephemeral loopback HTTP."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[3]
server_root = root / "integrations/prism-current/apps/server"
package_root = root / "minutes/MinutesKit"
fixture = Path(__file__).with_name("prism-contract-server.mts")
with tempfile.TemporaryDirectory(prefix="minutes-prism-contract-") as directory:
    ready = Path(directory) / "ready.json"
    token = Path(directory) / "synthetic-token"
    env = dict(os.environ, MINUTES_PRISM_CONTRACT_READY=str(ready), MINUTES_PRISM_CONTRACT_TOKENFILE=str(token))
    # Pin all safety-critical values even if the invoking shell has production env vars.
    env.update(DB_PATH=":memory:", PARACHUTE_URL="http://vault.test", PARACHUTE_TOKEN="test-vault-token",
               OWNER_EMAIL="owner@test.local", SESSION_SECRET="test-session-secret-do-not-use-in-prod",
               CAPABILITY_SECRET="test-capability-secret-do-not-use-in-prod")
    server = subprocess.Popen(["node", "--env-file=.env.test", "--import", "tsx", str(fixture)], cwd=server_root, env=env)
    try:
        deadline = time.monotonic() + 30
        while not ready.exists():
            if server.poll() is not None:
                raise RuntimeError("Synthetic Prism fixture exited before becoming ready")
            if time.monotonic() > deadline:
                raise TimeoutError("Synthetic Prism fixture startup timed out")
            time.sleep(0.1)
        env["MINUTES_PRISM_CONTRACT_URL"] = json.loads(ready.read_text())["origin"]
        result = subprocess.run(["swift", "test", "--filter", "PrismHTTPContractTests"], cwd=package_root, env=env)
        raise SystemExit(result.returncode)
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
