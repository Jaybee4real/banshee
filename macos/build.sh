#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

swiftc -O Sources/*.swift -o build/banshell-arm64 -target arm64-apple-macos13.0
swiftc -O Sources/*.swift -o build/banshell-x86_64 -target x86_64-apple-macos13.0
lipo -create -output build/banshell build/banshell-arm64 build/banshell-x86_64

APP=build/Banshell.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/banshell "$APP/Contents/MacOS/banshell"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f Assets/Banshell.icns ]; then
  cp Assets/Banshell.icns "$APP/Contents/Resources/Banshell.icns"
fi
codesign --force --deep -s - "$APP"
ditto -c -k --keepParent "$APP" build/Banshell-macOS.zip

VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
PKGROOT=build/pkgroot
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/Applications"
cp -R "$APP" "$PKGROOT/Applications/Banshell.app"
chmod +x pkg-scripts/postinstall
pkgbuild --root "$PKGROOT" --identifier com.jaybee.banshell --version "$VERSION" \
  --scripts pkg-scripts --install-location / build/Banshell-component.pkg >/dev/null
productbuild --package build/Banshell-component.pkg build/Banshell-macOS-Installer.pkg >/dev/null
rm -f build/Banshell-component.pkg

echo "built: $APP, build/Banshell-macOS.zip, build/Banshell-macOS-Installer.pkg"
