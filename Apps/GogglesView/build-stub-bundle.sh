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
#     <Apple ID> (<cert id>)", Team ID U8LK2QA3FL) -- Task 2.3's
#     original "0 valid identities" state (see that task's report) no
#     longer holds on this machine.
#
# Task 4.1 also adds the third bundle component
# (`Contents/Library/SystemExtensions/`, the throwaway CMIOExtension
# mach-lookup spike -- see the original task notes (not kept in the repo)) and
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

# App Intents (ShortcutsIntents.swift): SwiftPM does not run the App Intents
# metadata extraction Xcode does, so we ask the compiler for const-value
# output of the intent protocols and run appintentsmetadataprocessor below.
# Without the resulting Contents/Resources/Metadata.appintents the actions do
# not show up in Shortcuts.
INTENTS_PROTOCOLS="$SCRIPT_DIR/.build/appintents-protocols.json"
mkdir -p "$SCRIPT_DIR/.build"
cat > "$INTENTS_PROTOCOLS" <<'JSON'
["AppIntent","EntityQuery","AppEntity","TransientAppEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","IntentValueQuery"]
JSON

echo "==> Building GogglesView app binary (swift build)"
( cd "$SCRIPT_DIR" && swift build -c release \
    -Xswiftc -emit-const-values \
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
    -Xswiftc -Xfrontend -Xswiftc "$INTENTS_PROTOCOLS" )
APP_BIN="$SCRIPT_DIR/.build/release/GogglesView"
if [[ ! -x "$APP_BIN" ]]; then
    echo "error: expected app binary not found at $APP_BIN" >&2
    exit 1
fi

# Generate Metadata.appintents (best effort: on failure the app still works,
# the Shortcuts actions are just not listed; URL scheme/AppleScript are
# unaffected). Output: $INTENTS_META/Metadata.appintents.
INTENTS_META=""
echo "==> Generating App Intents metadata"
INTENTS_TMP="$(mktemp -d)"
TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
CONST_LIST="$INTENTS_TMP/const.txt"
find "$SCRIPT_DIR/.build/out/Intermediates.noindex/GogglesView.build/Release" -name '*.swiftconstvalues' > "$CONST_LIST" 2>/dev/null || true
find "$SCRIPT_DIR/Sources/GogglesView" -name '*.swift' > "$INTENTS_TMP/src.txt"
if [[ -n "$PROCESSOR" && -s "$CONST_LIST" ]] && "$PROCESSOR" \
    --output "$INTENTS_TMP/out" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name GogglesView \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple "$(uname -m)-apple-macos14.0" \
    --source-file-list "$INTENTS_TMP/src.txt" \
    --swift-const-vals-list "$CONST_LIST" \
    --force > "$INTENTS_TMP/log.txt" 2>&1 \
    && [[ -f "$INTENTS_TMP/out/Metadata.appintents/extract.actionsdata" ]]; then
    INTENTS_META="$INTENTS_TMP/out/Metadata.appintents"
else
    echo "warning: App Intents metadata not generated; Shortcuts actions will not be listed" >&2
    cat "$INTENTS_TMP/log.txt" >&2 2>/dev/null || true
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
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchAgents"

cp "$SCRIPT_DIR/BundleResources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/BundleResources/com.kburiasco.gogglesview.helper.plist" \
   "$APP_BUNDLE/Contents/Library/LaunchDaemons/com.kburiasco.gogglesview.helper.plist"
# Opt-in plug-in auto-open agent (AutoOpenRegistration). Covered by the bundle
# seal; plists aren't signed individually.
cp "$SCRIPT_DIR/BundleResources/com.kburiasco.gogglesview.autoopen.plist" \
   "$APP_BUNDLE/Contents/Library/LaunchAgents/com.kburiasco.gogglesview.autoopen.plist"

# AppleScript dictionary (Info.plist OSAScriptingDefinition -> Resources/).
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$SCRIPT_DIR/BundleResources/GogglesView.sdef" "$APP_BUNDLE/Contents/Resources/GogglesView.sdef"
cp "$SCRIPT_DIR/BundleResources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if [[ -n "$INTENTS_META" ]]; then
    cp -R "$INTENTS_META" "$APP_BUNDLE/Contents/Resources/Metadata.appintents"
fi

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
codesign --verify --strict --verbose=2 "$APP_BUNDLE" 2>&1
grep -q autoopen "$APP_BUNDLE/Contents/_CodeSignature/CodeResources" && echo "autoopen.plist sealed in bundle"

echo "==> Done: $APP_BUNDLE"
