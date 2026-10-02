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
#   - Otherwise the first *valid* codesigning identity from
#     `security find-identity -v -p codesigning` is used, or ad-hoc
#     (`--sign -`, "TeamIdentifier=not set") if there are none. As of Task
#     4.1 this machine has exactly one valid identity ("Apple Development:
#     kburiasco@gmail.com (S222VMFC76)", Team ID U8LK2QA3FL) -- Task 2.3's
#     original "0 valid identities" state (see that task's report) no
#     longer holds on this machine.
#
# Task 4.1 also adds the third bundle component
# (`Contents/Library/SystemExtensions/`, the throwaway CMIOExtension
# mach-lookup spike -- see `.superpowers/sdd/plan/task-4.1-report.md`) and
# entitlements-based signing for both the app and the extension (needed for
# `com.apple.developer.system-extension.install` / app-sandbox /
# application-groups) -- previously nothing in this script passed
# `--entitlements` at all.

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

# Task 4.1: third bundle component, the throwaway CMIOExtension spike
# (Extension/GogglesCamera). Built and assembled here too so the app
# bundle is genuinely installable end-to-end for the mach-lookup spike --
# skipped gracefully (with a warning) if that directory doesn't exist,
# so this script keeps working for anyone checking out a pre-4.1 commit.
EXT_DIR="$REPO_ROOT/Extension/GogglesCamera"
EXT_BIN=""
if [[ -d "$EXT_DIR" && -f "$EXT_DIR/Package.swift" ]]; then
    echo "==> Building GogglesCameraExtension (release)"
    ( cd "$EXT_DIR" && swift build -c release )
    EXT_BIN="$EXT_DIR/.build/release/GogglesCameraExtension"
    if [[ ! -x "$EXT_BIN" ]]; then
        echo "error: expected extension binary not found at $EXT_BIN" >&2
        exit 1
    fi
else
    echo "==> Skipping GogglesCameraExtension (Extension/GogglesCamera not present yet)"
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

if [[ -n "$EXT_BIN" ]]; then
    EXT_BUNDLE="$APP_BUNDLE/Contents/Library/SystemExtensions/com.kburiasco.gogglesview.camera.systemextension"
    mkdir -p "$EXT_BUNDLE/Contents/MacOS"
    cp "$EXT_DIR/BundleResources/Info.plist" "$EXT_BUNDLE/Contents/Info.plist"
    cp "$EXT_BIN" "$EXT_BUNDLE/Contents/MacOS/GogglesCameraExtension"
fi

echo "==> Code-signing GogglesHelper (hardened runtime)"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/GogglesHelper"

if [[ -n "$EXT_BIN" ]]; then
    echo "==> Code-signing GogglesCamera.systemextension (hardened runtime + entitlements)"
    codesign --force --options runtime \
        --entitlements "$EXT_DIR/BundleResources/GogglesCamera.entitlements" \
        --sign "$SIGN_IDENTITY" "$EXT_BUNDLE"
fi

# GOGGLESVIEW_WITH_EXTENSION_INSTALL=1 opts into the
# com.apple.developer.system-extension.install entitlement for testing
# Task 4.1's OSSystemExtensionRequest path -- requires a paid Apple
# Developer Program membership just to provision (confirmed via AMFI -413
# "No matching profile found"; see docs/dev-setup.md). Without that
# membership, building WITH this entitlement makes the whole app fail
# AMFI validation and refuse to launch at all, not just refuse to install
# the extension -- so it's opt-in, not the default.
if [[ -n "${GOGGLESVIEW_WITH_EXTENSION_INSTALL:-}" ]]; then
    APP_ENTITLEMENTS="$SCRIPT_DIR/BundleResources/GogglesView-with-extension-install.entitlements"
    echo "==> GOGGLESVIEW_WITH_EXTENSION_INSTALL set: using $APP_ENTITLEMENTS"
else
    APP_ENTITLEMENTS="$SCRIPT_DIR/BundleResources/GogglesView.entitlements"
fi

echo "==> Code-signing GogglesView (app binary, entitlements)"
codesign --force --options runtime \
    --entitlements "$APP_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/GogglesView"

echo "==> Code-signing the app bundle as a whole"
codesign --force --options runtime \
    --entitlements "$APP_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

echo "==> Verifying signatures"
echo "--- GogglesHelper ---"
codesign -dv --verbose=2 "$APP_BUNDLE/Contents/MacOS/GogglesHelper" 2>&1
echo "--- GogglesView ---"
codesign -dv --verbose=2 "$APP_BUNDLE/Contents/MacOS/GogglesView" 2>&1
if [[ -n "$EXT_BIN" ]]; then
    echo "--- GogglesCamera.systemextension ---"
    codesign -dv --verbose=2 "$EXT_BUNDLE" 2>&1
fi
echo "--- bundle ---"
codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1

echo "==> Done: $APP_BUNDLE"
