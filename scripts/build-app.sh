#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
VERSION=$(plutil -extract version raw version.json)
BUILD=$(plutil -extract build raw version.json)
BUNDLE_ID=$(plutil -extract bundleIdentifier raw version.json)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Invalid version" >&2; exit 1; }
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid build number" >&2; exit 1; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "Invalid bundle identifier" >&2; exit 1; }
cat > .build/AppVersion.swift <<SWIFT
import Foundation
enum AppVersion {
    static let version = "$VERSION"
    static let build = "$BUILD"
    static let bundleIdentifier = "$BUNDLE_ID"
}
SWIFT
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 Sources/TokenTank/*.swift .build/AppVersion.swift -o .build/TokenTank
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/generate-icon.swift .build/AppIcon.png
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" .build/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" .build/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o .build/AppIcon.icns
APP="$PWD/dist/近星点.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/TokenTank "$APP/Contents/MacOS/TokenTank"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TokenTank</string>
<key>CFBundleIdentifier</key><string>org.sourcepowered.tokentank</string>
<key>CFBundleName</key><string>近星点</string>
<key>CFBundleDisplayName</key><string>近星点</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
