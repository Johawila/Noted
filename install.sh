#!/bin/bash
# Build Noted and install it to /Applications with an ad-hoc signature.
#
# Ad-hoc signing is the whole point: a development-signed build stops launching
# after ~14 days when its provisioning profile expires, which is what killed the
# app twice already. An ad-hoc signature never expires. It also means we never
# need Xcode's Archive/Export flow — that exists for notarised distribution,
# which this app doesn't do.
set -euo pipefail

cd "$(dirname "$0")"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "==> Building Release"
xcodebuild -project Noted.xcodeproj -scheme Noted -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build > "$BUILD_DIR/build.log" 2>&1 || { tail -40 "$BUILD_DIR/build.log"; exit 1; }

APP="$BUILD_DIR/Build/Products/Release/Noted.app"
[ -d "$APP" ] || { echo "No app at $APP"; exit 1; }

echo "==> Signing ad-hoc"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP"

# The running copy holds the global hotkey registration, so it has to go first.
if pgrep -f "/Applications/Noted.app/Contents/MacOS/Noted" > /dev/null; then
    echo "==> Quitting running instance"
    osascript -e 'quit app "Noted"' 2>/dev/null || pkill -f "/Applications/Noted.app/Contents/MacOS/Noted"
    while pgrep -f "/Applications/Noted.app/Contents/MacOS/Noted" > /dev/null; do sleep 0.3; done
fi

echo "==> Installing to /Applications"
rm -rf /Applications/Noted.app
cp -R "$APP" /Applications/Noted.app
xattr -dr com.apple.quarantine /Applications/Noted.app 2>/dev/null || true

echo "==> Launching"
open /Applications/Noted.app
codesign -dv /Applications/Noted.app 2>&1 | grep -E "Signature|TeamIdentifier"
