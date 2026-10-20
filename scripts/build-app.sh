#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${MINUTES_BUILD_DIR:-$ROOT_DIR/build}"
APP_BUNDLE="$BUILD_DIR/Minutes.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

SWIFT_BUILD_OPTIONS=()
if [[ "${MINUTES_SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
    SWIFT_BUILD_OPTIONS+=(--disable-sandbox)
fi

echo "==> Building MinutesApp in release mode..."
swift build "${SWIFT_BUILD_OPTIONS[@]}" -c release --product MinutesApp --package-path "$ROOT_DIR/MinutesKit"
BIN_DIR="$(swift build "${SWIFT_BUILD_OPTIONS[@]}" -c release --show-bin-path --package-path "$ROOT_DIR/MinutesKit")"
BIN_PATH="$BIN_DIR/MinutesApp"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Error: Release binary not found at $BIN_PATH"
    exit 1
fi

echo "==> Constructing macOS application bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/Minutes"
cp "$ROOT_DIR/Apps/Shared/PrivacyInfo.xcprivacy" "$RESOURCES_DIR/PrivacyInfo.xcprivacy"
cp "$ROOT_DIR/Apps/Shared/Minutes.icns" "$RESOURCES_DIR/Minutes.icns"
# macOS 26 reads CFBundleIconName from a compiled catalog for some surfaces
# (for example the app badge on minimized windows); keep the .icns as fallback.
ICON_PARTIAL_PLIST="$(mktemp -t minutes-icon).plist"
xcrun actool --compile "$RESOURCES_DIR" --platform macosx --minimum-deployment-target 15.0 \
    --app-icon AppIcon --output-partial-info-plist "$ICON_PARTIAL_PLIST" \
    --warnings --errors "$ROOT_DIR/Apps/Shared/MacAssets.xcassets" >/dev/null
[[ -f "$RESOURCES_DIR/Assets.car" ]] || { echo "Error: app icon catalog was not compiled" >&2; exit 1; }
ditto "$ROOT_DIR/Apps/Shared/Licenses" "$RESOURCES_DIR/Licenses"
chmod +x "$MACOS_DIR/Minutes"

# SwiftPM Bundle.module searches Bundle.main.resourceURL for these bundles.
# Copy every product resource bundle, rather than relying on a checkout path.
for resource_bundle in "$BIN_DIR"/*.bundle(N); do
    ditto "$resource_bundle" "$RESOURCES_DIR/${resource_bundle:t}"
done
if [[ ! -d "$RESOURCES_DIR/FluidAudio_FluidAudio.bundle" ]]; then
    echo "Error: FluidAudio SwiftPM resource bundle missing from release products" >&2
    exit 1
fi

# FluidAudio 0.17.7's NemoTextProcessing xcframework contains a static .a;
# it does not require embedding a dynamic framework. Refuse future unsupported
# dynamic dependencies instead of silently shipping checkout-relative links.
while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/*|/usr/lib/*) ;;
        *) echo "Error: Non-system dynamic dependency needs explicit embedding/rpath handling: $dependency" >&2; exit 1 ;;
    esac
done < <(otool -L "$MACOS_DIR/Minutes" | awk 'NR > 1 { print $1 }')

# Embed exactly the same privacy identity in the Mach-O and app wrapper.
cp "$ROOT_DIR/MinutesKit/Sources/MinutesApp/Info.plist" "$CONTENTS_DIR/Info.plist"
python3 "$ROOT_DIR/scripts/verify-app-privacy.py" "$APP_BUNDLE"
if [[ "${MINUTES_BUNDLE_GOOGLE_REGISTRATION:-0}" == "1" ]]; then
    python3 "$ROOT_DIR/scripts/inject-google-registration.py" "$APP_BUNDLE"
fi

ENTITLEMENTS="$ROOT_DIR/scripts/Minutes.entitlements"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"
if [[ -n "$NOTARY_PROFILE" && "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Error: Notarization requires DEVELOPER_ID_APPLICATION; an ad-hoc build cannot be notarized." >&2
    exit 1
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGN_OPTIONS=(--force --sign -)
    ARCHIVE_NAME="Minutes-1.0.0-local-test.zip"
    echo "==> Ad-hoc signing for local testing only (not notarized or distribution-ready)"
else
    SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)
    ARCHIVE_NAME="Minutes-1.0.0-signed-unnotarized.zip"
    echo "==> Signing with Developer ID; notarization remains a separate required release step"
fi

# Sign nested resource bundles before the containing application.
for resource_bundle in "$RESOURCES_DIR"/*.bundle(N); do
    codesign "${SIGN_OPTIONS[@]}" "$resource_bundle"
done
codesign "${SIGN_OPTIONS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Packaging verified local artifact..."
ARCHIVE_PATH="$BUILD_DIR/$ARCHIVE_NAME"
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> Submitting signed archive to Apple notarization..."
    NOTARY_RESULT="$BUILD_DIR/minutes-notarization.json"
    xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$NOTARY_RESULT"
    NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT")"
    if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
        echo "Error: Apple notarization status is $NOTARY_STATUS; see $NOTARY_RESULT." >&2
        exit 1
    fi
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
    ARCHIVE_PATH="$BUILD_DIR/Minutes-1.0.0-notarized.zip"
    rm -f "$ARCHIVE_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
fi

echo "==> Minutes package created; clean-device validation is still required"
echo "    App: $APP_BUNDLE"
echo "    Zip: $ARCHIVE_PATH"
