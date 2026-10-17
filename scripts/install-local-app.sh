#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:?Usage: install-local-app.sh /absolute/path/to/Minutes.app}"
DESTINATION="$HOME/Applications/Minutes.app"
REGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ "$SOURCE" = /* && -d "$SOURCE/Contents/MacOS" ]] || { print -u2 'Expected an absolute Minutes.app bundle path'; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" = ai.nosaas.minutes ]] || { print -u2 'Unexpected application identity'; exit 1; }
# Never replace a live app, especially while it may be recording.
running_executables="$(/bin/ps -axo comm=)"
if [[ "$running_executables" == *"$DESTINATION/Contents/MacOS/Minutes"* ]]; then
    print -u2 'Quit the installed Minutes app before updating it.'; exit 1
fi
codesign --verify --deep --strict "$SOURCE"
mkdir -p "$HOME/Applications"
TEMPORARY="$HOME/Applications/.Minutes-install-$$"
trap 'rm -rf "$TEMPORARY"' EXIT
ditto "$SOURCE" "$TEMPORARY"
codesign --verify --deep --strict "$TEMPORARY"
if [[ -d "$DESTINATION" ]]; then
    mkdir -p "$ROOT_DIR/build/install-backups"
    ditto -c -k --sequesterRsrc --keepParent "$DESTINATION" "$ROOT_DIR/build/install-backups/Minutes-$(date +%Y%m%d-%H%M%S).zip"
    "$REGISTER" -u "$DESTINATION" || true
    rm -rf "$DESTINATION"
fi
mv "$TEMPORARY" "$DESTINATION"
# Preview app bundles stay on disk, but must not compete for permission relaunches.
for preview in "$ROOT_DIR"/build/**/Minutes.app(N); do
    "$REGISTER" -u "$preview" || true
done
"$REGISTER" -f "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
print "Installed: $DESTINATION"
print 'Open this exact copy for recording and privacy permissions.'
