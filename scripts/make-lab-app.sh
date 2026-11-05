#!/bin/sh
# Build Voicely Lab from this checkout and pack it into "Voicely Lab.app"
# (bundle id art.voicely.lab, ad-hoc signed). The official Voicely is left
# untouched; the two share only the downloaded model files.
# The CLI goes into Contents/Helpers/voicely, as in the official app, so
# scripts can call "/Applications/Voicely Lab.app/Contents/Helpers/voicely".
#
# Usage: scripts/make-lab-app.sh [output dir]    (default: .build/lab)
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-.build/lab}"

swift build -c release --product Voicely
swift build -c release --product VoicelyCLI
BUILD="$(swift build -c release --show-bin-path)"

APP="$OUT/Voicely Lab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BUILD/Voicely" "$APP/Contents/MacOS/Voicely"
cp "$BUILD/VoicelyCLI" "$APP/Contents/Helpers/voicely"
for bundle in "$BUILD"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cp Sources/Voicely/Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/"  # MIT: notice travels with every copy of the binary

ICON=/Applications/Voicely.app/Contents/Resources/AppIcon.icns
# Without the official Voicely installed, reuse the icon of the installed Lab.
[ -f "$ICON" ] || ICON="/Applications/Voicely Lab.app/Contents/Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/"
else
  echo "note: $ICON not found, the app goes without an icon"
fi

# Nested code is signed before the bundle that seals it.
codesign --force --sign - --options runtime --identifier art.voicely.lab.cli "$APP/Contents/Helpers/voicely"
codesign --force --sign - --options runtime \
  --entitlements Sources/Voicely/Resources/Voicely.entitlements \
  --identifier art.voicely.lab "$APP"
codesign --verify --strict --verbose=2 "$APP"
"$APP/Contents/Helpers/voicely" --version >/dev/null
echo "Built: $APP"
