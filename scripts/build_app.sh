#!/bin/bash
# Builds a universal Sugrob.app, plus a DMG and ZIP in dist/.
# Needs only the Xcode Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
NAME="Sugrob"
VERSION="${1:-$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' Sources/Sugrob/Support.swift)}"
DIST="$ROOT/dist"
APP="$DIST/$NAME.app"
ONLY_NATIVE="${ONLY_NATIVE:-0}"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
if [ "$ONLY_NATIVE" = "1" ]; then
    swift build -c release
    cp ".build/release/$NAME" "$APP/Contents/MacOS/$NAME"
else
    swift build -c release --triple arm64-apple-macosx13.0 --scratch-path .build/arm64
    swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path .build/x86_64
    lipo -create -output "$APP/Contents/MacOS/$NAME" \
        ".build/arm64/arm64-apple-macosx/release/$NAME" \
        ".build/x86_64/x86_64-apple-macosx/release/$NAME"
fi

echo "==> Icon"
ICONSET="$DIST/AppIcon.iconset"
"$APP/Contents/MacOS/$NAME" --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>io.github.sugrob.app</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
</dict>
</plist>
PLIST

echo "==> Signing"
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$APP"
else
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi

echo "==> Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg"
rm -rf "$STAGE"

echo "==> Done"
lipo -info "$APP/Contents/MacOS/$NAME"
du -sh "$APP" "$DIST/$NAME.dmg" "$DIST/$NAME.zip"
