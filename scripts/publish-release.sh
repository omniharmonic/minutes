#!/bin/zsh
# Publishes a notarized Mac build: GitHub release on omniharmonic/minutes-releases,
# EdDSA-signed for Sparkle, and a new item at the top of appcast.xml.
# Usage: scripts/publish-release.sh build/release66 "What changed, one line per item"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:?Usage: publish-release.sh <build-dir> <release notes>}"
NOTES="${2:?Give release notes}"
REPO=omniharmonic/minutes-releases
APP="$BUILD/Minutes.app"
SOURCE_ZIP="$BUILD/Minutes-1.0.0-notarized.zip"
SIGN_UPDATE="$ROOT_DIR/MinutesKit/.build/artifacts/sparkle/Sparkle/bin/sign_update"

[[ -f "$SOURCE_ZIP" ]] || { echo "Error: $SOURCE_ZIP not found; build with NOTARYTOOL_PROFILE first." >&2; exit 1; }
xcrun stapler validate "$APP" >/dev/null || { echo "Error: the app is not notarized and stapled." >&2; exit 1; }
spctl --assess --type execute "$APP" || { echo "Error: Gatekeeper rejects the app." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
TAG="v$VERSION-$BUILD_NUMBER"
ASSET="Minutes-$VERSION-$BUILD_NUMBER.zip"
WORK="$(mktemp -d -t minutes-release)"
trap 'rm -rf "$WORK"' EXIT

cp "$SOURCE_ZIP" "$WORK/$ASSET"
# Also published as Minutes.zip so the README's "latest" link never changes.
cp "$SOURCE_ZIP" "$WORK/Minutes.zip"
SIGNATURE="$("$SIGN_UPDATE" --account ai.nosaas.minutes "$WORK/$ASSET")"  # sparkle:edSignature="…" length="…"

gh repo clone "$REPO" "$WORK/repo" -- -q
NOTES_HTML="$(print -r -- "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/^/<li>/' -e 's/$/<\/li>/')"
ITEM="    <item>
      <title>Minutes $VERSION ($BUILD_NUMBER)</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>$NOTES_HTML</ul>]]></description>
      <enclosure url=\"https://github.com/$REPO/releases/download/$TAG/$ASSET\" $SIGNATURE type=\"application/octet-stream\"/>
    </item>"
python3 - "$WORK/repo/appcast.xml" "$ITEM" <<'EOF'
import sys
path, item = sys.argv[1], sys.argv[2]
feed = open(path).read()
marker = "  </channel>"
first_item = feed.find("    <item>")
at = first_item if first_item >= 0 else feed.index(marker)
open(path, "w").write(feed[:at] + item + "\n" + feed[at:])
EOF

gh release create "$TAG" "$WORK/$ASSET" "$WORK/Minutes.zip" --repo "$REPO" --title "Minutes $VERSION ($BUILD_NUMBER)" --notes "$NOTES"
# The feed goes live only after the download exists.
git -C "$WORK/repo" add appcast.xml
git -C "$WORK/repo" commit -q -m "Minutes $VERSION ($BUILD_NUMBER)"
git -C "$WORK/repo" push -q
echo "Published $TAG: https://github.com/$REPO/releases/tag/$TAG"
