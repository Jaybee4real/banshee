#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

swiftc -O Sources/*.swift -o build/banshee-arm64 -target arm64-apple-macos13.0
swiftc -O Sources/*.swift -o build/banshee-x86_64 -target x86_64-apple-macos13.0
lipo -create -output build/banshee build/banshee-arm64 build/banshee-x86_64

APP=build/Banshee.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/banshee "$APP/Contents/MacOS/banshee"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f Assets/Banshee.icns ]; then
  cp Assets/Banshee.icns "$APP/Contents/Resources/Banshee.icns"
fi
codesign --force --deep -s - "$APP"
ditto -c -k --keepParent "$APP" build/Banshee-macOS.zip
echo "built: $APP and build/Banshee-macOS.zip"
