# Third-party notices

## libusb (bundled)

`Vendor/libusb` contains libusb 1.0.27, statically linked into `GogglesHelper`.

- License: GNU LGPL v2.1 or later. See https://github.com/libusb/libusb/blob/v1.0.27/COPYING
- Source: https://github.com/libusb/libusb/releases/tag/v1.0.27
- Build recipe: `Vendor/libusb/VERSION.md`

GogglesView itself is GPL-3.0-or-later (see `LICENSE`), which is compatible with the LGPL. You may rebuild the helper against a modified libusb by replacing `Vendor/libusb/lib/libusb-1.0.a` and running the build script.

## Optional libraries loaded at runtime (not bundled)

These are not distributed with GogglesView. If you install them yourself, the app loads them from standard paths or from a path set in Settings.

- libsrt (SRT output): MPL-2.0. https://github.com/Haivision/srt
- NDI runtime (NDI output): proprietary, governed by NDI's own license. Obtain it from https://ndi.video. Do not redistribute it with GogglesView builds.

NDI is a trademark of Vizrt NDI AB.

## Trademarks

GogglesView is an independent project. It is not affiliated with, authorized, or endorsed by SZ DJI Technology Co., Ltd. "DJI" and "Goggles 3" are trademarks of their respective owners. The USB protocol was reverse-engineered for interoperability.
