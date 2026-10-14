#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Minutes.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Building MinutesApp in release mode..."
swift build -c release --product MinutesApp --package-path "$ROOT_DIR/MinutesKit"

BIN_PATH="$ROOT_DIR/MinutesKit/.build/release/MinutesApp"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Error: Release binary not found at $BIN_PATH"
    exit 1
fi

echo "==> Constructing macOS application bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/Minutes"
chmod +x "$MACOS_DIR/Minutes"

cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Minutes</string>
    <key>CFBundleIdentifier</key>
    <string>ai.nosaas.minutes</string>
    <key>CFBundleName</key>
    <string>Minutes</string>
    <key>CFBundleDisplayName</key>
    <string>Minutes</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Minutes requires microphone access to record meetings for local transcription and diarization.</string>
</dict>
</plist>
EOF

ENTITLEMENTS="$ROOT_DIR/scripts/Minutes.entitlements"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"

echo "==> Signing application bundle (Identity: $SIGNING_IDENTITY)..."
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
fi

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Packaging distributable zip..."
(cd "$BUILD_DIR" && zip -r -q "Minutes-1.0.0.zip" "Minutes.app")

echo "==> Minutes application bundle successfully packaged at:"
echo "    App: $APP_BUNDLE"
echo "    Zip: $BUILD_DIR/Minutes-1.0.0.zip"
