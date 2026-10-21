#!/usr/bin/env bash
# Builds build/Authenticator.app (release, Apple Silicon) and ad-hoc signs it.
#   scripts/build-app.sh                 # ad-hoc signature
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCH="${ARCH:-arm64}"

swift build -c "$CONFIG" --arch "$ARCH" --product Authenticator
BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"

APP="build/Authenticator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Authenticator" "$APP/Contents/MacOS/Authenticator"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Optional icon: put a 1024×1024 PNG at Support/AppIcon.png (or a ready AppIcon.icns).
if [[ -f Support/AppIcon.icns ]]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [[ -f Support/AppIcon.png ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Support/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Support/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --options runtime --entitlements Support/Authenticator.entitlements --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
echo "Run:  open $APP      Install: cp -R $APP /Applications/"
