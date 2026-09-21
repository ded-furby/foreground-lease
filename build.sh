#!/bin/sh
# Builds build/Lease.app and build/Lease.dmg. Needs Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
APP=build/Lease.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit -framework ApplicationServices \
  -o "$APP/Contents/MacOS/Lease" Sources/main.swift
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"  # ad-hoc by default; a real identity keeps the Accessibility grant across rebuilds
mkdir build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname Lease -srcfolder build/dmg -ov -format UDZO -quiet build/Lease.dmg
echo "built $APP and build/Lease.dmg"
