#!/bin/sh
# Builds "build/Magic Pics.app" (release, ad-hoc signed).
set -e
cd "$(dirname "$0")"

swift build -c release
APP="build/Magic Pics.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MagicPics" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/" # regenerate with: swift Icon/make-icon.swift
codesign --force --sign - "$APP"
echo "Built $APP"
