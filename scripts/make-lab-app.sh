#!/bin/sh
# Build Voicely Lab from this checkout and pack it into "Voicely Lab.app"
# (bundle id art.voicely.lab, ad-hoc signed). The official Voicely is left
# untouched; the two share only the downloaded model files.
#
# Usage: scripts/make-lab-app.sh [output dir]    (default: .build/lab)
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-.build/lab}"

swift build -c release --product Voicely
BUILD="$(swift build -c release --show-bin-path)"

APP="$OUT/Voicely Lab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Voicely" "$APP/Contents/MacOS/Voicely"
for bundle in "$BUILD"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cp Sources/Voicely/Resources/Info.plist "$APP/Contents/Info.plist"

ICON=/Applications/Voicely.app/Contents/Resources/AppIcon.icns
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/"
else
  echo "note: $ICON not found, the app goes without an icon"
fi

codesign --force --sign - --options runtime \
  --entitlements Sources/Voicely/Resources/Voicely.entitlements \
  --identifier art.voicely.lab "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built: $APP"
