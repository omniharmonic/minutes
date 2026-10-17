#!/bin/sh
set -eu
apps_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# XcodeGen is intentionally supplied by the developer; nothing installs globally.
# Verified upstream release: 2.46.0, xcodegen.zip SHA256:
# 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
xcodegen_bin=${XCODEGEN_BIN:-xcodegen}
if [ "$("$xcodegen_bin" --version)" != "Version: 2.46.0" ]; then
  echo "Use the pinned official XcodeGen 2.46.0 executable via XCODEGEN_BIN." >&2
  exit 1
fi
exec "$xcodegen_bin" generate --spec "$apps_dir/project.yml" --project "$apps_dir"
