#!/usr/bin/env python3
"""Owner-approved native public-client registration injection. Never print values."""
import json, os, pathlib, plistlib, subprocess, sys
bundle = pathlib.Path(sys.argv[1])
metadata = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
client = metadata.get("GoogleDesktopClientID")
if not isinstance(client, str) or not client.endswith(".apps.googleusercontent.com"):
    raise SystemExit("Desktop public client ID missing from application metadata")
try:
    result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "app.minutes.oauth.google-desktop-client", "-a", client, "-w"], capture_output=True, check=True)
    raw = result.stdout.strip()
    value = json.loads(raw)
except (subprocess.CalledProcessError, ValueError):
    raise SystemExit("Native desktop registration is unavailable in Keychain; release injection stopped") from None
if set(value) != {"clientID", "clientSecret"} or value["clientID"] != client or not isinstance(value["clientSecret"], str) or not 0 < len(value["clientSecret"].encode()) <= 1024 or any(c.isspace() for c in value["clientSecret"]):
    raise SystemExit("Native desktop registration failed validation")
data = json.dumps(value, separators=(",", ":")).encode()
if len(data) > 4096:
    raise SystemExit("Native desktop registration exceeds allowed size")
path = bundle / "Contents/Resources/GoogleDesktopClientRegistration.json"
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
with os.fdopen(fd, "wb") as target:
    target.write(data)
print("Approved desktop native registration injected; user tokens excluded")
