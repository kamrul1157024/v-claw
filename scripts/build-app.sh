#!/bin/sh
# Assembles build/v-claw.app by hand. No Xcode project is involved.
#
# A locally built app carries no com.apple.quarantine attribute, so Gatekeeper does not
# block it. That is why v-claw needs no Developer ID and no notarization. The ad-hoc
# signature below is for a stable bundle identity across rebuilds, nothing more.
set -eu

cd "$(dirname "$0")/.."

APP=build/v-claw.app
CONTENTS=$APP/Contents

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp resources/Info.plist "$CONTENTS/Info.plist"
cp build/v-claw-app "$CONTENTS/MacOS/v-claw-app"

# The lock helper ships inside the bundle. internal/lock resolves it relative to the
# running executable, never through PATH.
cp build/v-claw-lock "$CONTENTS/MacOS/v-claw-lock"

[ -f resources/icons/AppIcon.icns ] && cp resources/icons/AppIcon.icns "$CONTENTS/Resources/"

codesign --force --sign - --timestamp=none "$CONTENTS/MacOS/v-claw-lock"
codesign --force --sign - --timestamp=none "$APP"

echo "built $APP"
