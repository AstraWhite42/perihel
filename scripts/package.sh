#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
VERSION=$(plutil -extract version raw version.json)
BUILD=$(plutil -extract build raw version.json)
STAGING=$(mktemp -d "$PWD/.build/share.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto --norsrc --noextattr "dist/近星点.app" "$STAGING/近星点.app"
cp docs/使用说明.md "$STAGING/使用说明.md"
ARCHIVE="$PWD/dist/近星点-${VERSION}-build${BUILD}-AppleSilicon.zip"
ditto -c -k --norsrc --noextattr "$STAGING" "$ARCHIVE"
(cd dist && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
printf 'Package: %s\n' "$ARCHIVE"
