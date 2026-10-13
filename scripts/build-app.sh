#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" Sources/TokenTank/main.swift -o .build/TokenTank
APP="$PWD/dist/Token Tank.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/TokenTank "$APP/Contents/MacOS/TokenTank"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TokenTank</string>
<key>CFBundleIdentifier</key><string>local.tokentank.app</string>
<key>CFBundleName</key><string>Token Tank</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
