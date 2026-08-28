#!/bin/bash
# Task 2.3: assemble GogglesView.app as a real, discoverable app bundle for
# SMAppService.daemon(plistName:) testing.
#
# Contents/MacOS/GogglesView is built from the real `GogglesView` SPM
# executable package (`Apps/GogglesView/Package.swift`, Task 3.1) -- a
# proper `swift build`, no longer a bare `swiftc` invocation of a standalone
# `StubApp/main.swift` (that file's contents moved into
# `Sources/GogglesView/main.swift` as part of Task 3.1's restructuring; see
# `Package.swift`'s doc comment for why). It's still not the real SwiftUI
# app (Task 3.4+), but as of Task 3.1 it links `GogglesXPC` and includes a
# real `HelperClient` exercised via `--test-client`, not just the
# registration-harness stub Task 2.3/2.4 left it as.
# Contents/MacOS/GogglesHelper is the REAL helper daemon built in Task 2.2.
#
# Reusable: Task 3.4+'s real SwiftUI app build should extend this script
# (or the layout it produces) rather than reinventing bundle assembly.
#
# Usage:
#   Apps/GogglesView/build-stub-bundle.sh [output_dir]
#
# output_dir defaults to Apps/GogglesView/build/GogglesView.app
#
# Signing identity selection (see task-2.3-report.md for why):
#   - GOGGLESVIEW_SIGN_IDENTITY env var overrides identity selection.
#   - Otherwise this machine has no valid (non-expired) codesigning identity
#     in the keychain (`security find-identity -v -p codesigning` -> 0 valid
#     identities), so this script falls back to ad-hoc signing (`--sign -`)
#     for both binaries. Ad-hoc signing produces "TeamIdentifier=not set" on
#     both -- see the report for what that means for the design §8.4
#     "same Team ID" checklist item.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_DIR="${1:-$SCRIPT_DIR/build}"
APP_BUNDLE="$OUT_DIR/GogglesView.app"

SIGN_IDENTITY="${GOGGLESVIEW_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    # Pick the first *valid* codesigning identity, if any; else ad-hoc.
    FOUND="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/^[[:space:]]*[0-9]+\)/ {print $2; exit}')"
    if [[ -n "$FOUND" ]]; then
        SIGN_IDENTITY="$FOUND"
    else
        SIGN_IDENTITY="-"
    fi
fi

echo "==> Using signing identity: $SIGN_IDENTITY"

echo "==> Building GogglesHelper (release)"
( cd "$REPO_ROOT/Helper/GogglesHelper" && swift build -c release )
HELPER_BIN="$REPO_ROOT/Helper/GogglesHelper/.build/release/GogglesHelper"
if [[ ! -x "$HELPER_BIN" ]]; then
    echo "error: expected helper binary not found at $HELPER_BIN" >&2
    exit 1
fi

echo "==> Building GogglesView app binary (swift build)"
( cd "$SCRIPT_DIR" && swift build -c release )
APP_BIN="$SCRIPT_DIR/.build/release/GogglesView"
if [[ ! -x "$APP_BIN" ]]; then
    echo "error: expected app binary not found at $APP_BIN" >&2
    exit 1
fi

echo "==> Assembling bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchDaemons"

cp "$SCRIPT_DIR/BundleResources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/BundleResources/com.kburiasco.gogglesview.helper.plist" \
   "$APP_BUNDLE/Contents/Library/LaunchDaemons/com.kburiasco.gogglesview.helper.plist"

cp "$APP_BIN" "$APP_BUNDLE/Contents/MacOS/GogglesView"
cp "$HELPER_BIN" "$APP_BUNDLE/Contents/MacOS/GogglesHelper"

echo "==> Code-signing GogglesHelper (hardened runtime)"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/GogglesHelper"

echo "==> Code-signing GogglesView (app binary)"
codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/GogglesView"

echo "==> Code-signing the app bundle as a whole"
codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

echo "==> Verifying signatures"
echo "--- GogglesHelper ---"
codesign -dv --verbose=2 "$APP_BUNDLE/Contents/MacOS/GogglesHelper" 2>&1
echo "--- GogglesView ---"
codesign -dv --verbose=2 "$APP_BUNDLE/Contents/MacOS/GogglesView" 2>&1
echo "--- bundle ---"
codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1

echo "==> Done: $APP_BUNDLE"
