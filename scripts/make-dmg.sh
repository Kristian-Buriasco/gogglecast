#!/bin/bash
# Usage: scripts/make-dmg.sh [path/to/GogglesView.app]
# Builds the app bundle (unless a bundle path is given) and creates
# dist/GogglesView-<version>.dmg containing the app and an /Applications symlink.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"

if [[ -z "$APP" ]]; then
    "$REPO_ROOT/Apps/GogglesView/build-stub-bundle.sh"
    APP="$REPO_ROOT/Apps/GogglesView/build/GogglesView.app"
fi
[[ -d "$APP" ]] || { echo "error: app bundle not found: $APP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DIST="$REPO_ROOT/dist"
DMG="$DIST/GogglesView-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$DIST"
cp -R "$APP" "$STAGE/GogglesView.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "GogglesView $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "==> Created $DMG"
