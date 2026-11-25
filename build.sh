#!/bin/sh
# Builds build/PicPress.app (release, ad-hoc signed).
set -e
cd "$(dirname "$0")"

swift build -c release
APP=build/PicPress.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/PicPress" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
