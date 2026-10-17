#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${MINUTES_BUILD_DIR:-$ROOT_DIR/build}"
EXPORT_IPA=0
if [[ "${1:-}" == "--export" && $# == 1 ]]; then
    EXPORT_IPA=1
elif [[ $# != 0 ]]; then
    echo "Usage: $0 [--export]" >&2
    exit 2
fi

"$ROOT_DIR/Apps/generate-project.sh"
# The generated source retains a build-setting placeholder; obtain its concrete value.
VERSION="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' "$ROOT_DIR/Apps/project.yml")"
[[ "$VERSION" == <-> ]] || { echo "Missing numeric CURRENT_PROJECT_VERSION" >&2; exit 1; }
ARCHIVE_PATH="$BUILD_DIR/Minutes-iOS-$VERSION.xcarchive"
[[ ! -e "$ARCHIVE_PATH" ]] || { echo "Archive already exists: $ARCHIVE_PATH; preserve or move it before rebuilding." >&2; exit 1; }
mkdir -p "$BUILD_DIR"

xcodebuild -project "$ROOT_DIR/Apps/Minutes.xcodeproj" -scheme MinutesiOS \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" -allowProvisioningUpdates archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/MinutesiOS.app"
python3 - "$APP_PATH" "$VERSION" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'app.minutes.ios'
assert info['CFBundleVersion'] == sys.argv[2]
assert info['CFBundleShortVersionString'] == '1.0.0'
assert info.get('ITSAppUsesNonExemptEncryption') is False
assert 'audio' in info.get('UIBackgroundModes', [])
assert info.get('MinimumOSVersion') == '18.0'
assert info.get('UIDeviceFamily') == [1, 2]
for key in ('NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription', 'NSCalendarsFullAccessUsageDescription'):
    assert isinstance(info.get(key), str) and info[key].strip(), key
assert not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False)
assert (app / 'Assets.car').is_file(), 'Missing compiled icon/assets'
assert info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName') == 'AppIcon'
privacy = plistlib.loads((app / 'PrivacyInfo.xcprivacy').read_bytes())
assert privacy.get('NSPrivacyTracking') is False
assert (app / 'FluidAudio_FluidAudio.bundle').is_dir(), 'Missing speech resources'
print('Archive identity, version, privacy, audio mode, ATS, icons and resources passed.')
print('Required device capabilities:', info.get('UIRequiredDeviceCapabilities', '(none declared)'))
PY
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Archive verified: $ARCHIVE_PATH"

if [[ "$EXPORT_IPA" == 1 ]]; then
    EXPORT_PATH="$BUILD_DIR/TestFlight$VERSION"
    xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$ROOT_DIR/scripts/ExportOptions-TestFlight.plist" \
        -allowProvisioningUpdates
    echo "Exported locally: $EXPORT_PATH (upload separately in Xcode Organizer or Transporter)"
fi
