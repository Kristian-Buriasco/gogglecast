// Trivial proof-of-link target for Task 0.2: link against the vendored static, universal
// libusb and print libusb_get_version(). This target is not part of the app's real
// dependency graph — it exists only to satisfy the task's exit criterion.

import CLibusb

let version = libusb_get_version().pointee
let rc = version.rc.map { String(cString: $0) } ?? ""
print("libusb version: \(version.major).\(version.minor).\(version.micro)\(rc)")
