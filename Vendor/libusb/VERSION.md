# Vendored libusb

- Version: 1.0.27 (source: https://github.com/libusb/libusb/releases/download/v1.0.27/libusb-1.0.27.tar.bz2)
- Build: static, universal (arm64 + x86_64), built with Xcode Command Line Tools clang
  via GNU autotools (`configure` script bundled in the release tarball — no autoconf/automake
  needed on this machine), then merged with `lipo -create`.
- `lib/libusb-1.0.a` — universal static archive (`lipo -info` reports `x86_64 arm64`).
- `include/libusb-1.0/libusb.h` — public header, identical output for both arch builds
  (confirmed with `diff`), copied from the arm64 build's `make install`.

## Build commands (reproducible)

```sh
curl -sL https://github.com/libusb/libusb/releases/download/v1.0.27/libusb-1.0.27.tar.bz2 -o libusb-1.0.27.tar.bz2
tar xjf libusb-1.0.27.tar.bz2
cd libusb-1.0.27

mkdir build-arm64 && cd build-arm64
CC="clang -arch arm64" ../configure --host=aarch64-apple-darwin \
    --enable-static --disable-shared --prefix="$PWD/../../out-arm64"
make -j8 && make install
cd ..

mkdir build-x86_64 && cd build-x86_64
CC="clang -arch x86_64" ../configure --host=x86_64-apple-darwin \
    --enable-static --disable-shared --prefix="$PWD/../../out-x86_64"
make -j8 && make install
cd ..

lipo -create out-arm64/lib/libusb-1.0.a out-x86_64/lib/libusb-1.0.a \
    -output libusb-1.0-universal.a
```

Only Xcode Command Line Tools were available on the build machine (no full Xcode.app),
so `xcodebuild -create-xcframework` was not an option — this is a raw vendored static
archive + module map, not an XCFramework.

libusb ships CMake support only from 1.0.28 onward; 1.0.27 was built via the bundled
autotools `configure` script instead (autoconf/automake themselves are not installed on
this machine, but the release tarball's pre-generated `configure` doesn't need them).
