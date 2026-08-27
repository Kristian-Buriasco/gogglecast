#!/bin/sh
# Helper for running `swift test` on this machine, which has only the Xcode
# Command Line Tools installed (no full Xcode.app).
#
# Without a full Xcode install, `swift test`'s default swift-testing runner
# fails at runtime with a dyld "Library not loaded" error for
# Testing.framework / lib_TestingInterop.dylib, because those live under
# CommandLineTools' own Frameworks directory rather than on the default
# dyld search paths. Pointing DYLD_FRAMEWORK_PATH / DYLD_LIBRARY_PATH at
# that directory fixes it.
#
# Second CLT-only gotcha (hit once real `@Test` functions were added in
# task 1.1): compiling any file that uses the `@Test`/`#expect` macros
# fails with "external macro implementation type
# 'TestingMacros.TestDeclarationMacro' could not be found for macro
# 'Test'; plugin for module 'TestingMacros' not found". The plugin
# (`libTestingMacros.dylib`) is present on disk under the CLT's
# `usr/lib/swift/host/plugins/testing` directory, but bare `swift test`
# doesn't discover it there without a full Xcode.app toolchain description.
# Passing `-plugin-path` explicitly fixes it.
#
# Usage: Packages/swift-test-clt.sh <path-to-package-dir>
set -eu

PKG_DIR="${1:-.}"
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
CLT_TESTING_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

(
  cd "$PKG_DIR"
  DYLD_FRAMEWORK_PATH="$CLT_FRAMEWORKS" \
  DYLD_LIBRARY_PATH="$CLT_LIB" \
  swift test -Xswiftc -plugin-path -Xswiftc "$CLT_TESTING_PLUGINS"
)
