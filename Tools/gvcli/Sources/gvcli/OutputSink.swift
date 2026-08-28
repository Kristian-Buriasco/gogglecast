import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Raw Annex-B output sink for `gvcli stream`/`gvcli replay`.
///
/// Opens `path` for writing via a plain POSIX `open()` call rather than
/// `FileHandle(forWritingAtPath:)` or the newer `FileHandle.write(contentsOf:)`
/// API, for two reasons:
///
///   1. `open()`-for-write on a FIFO blocks the calling thread until a
///      reader attaches (`man 4 fifo`) -- exactly `stream.py`'s
///      `open(fifo_path, "wb")` behavior, which this type is required to
///      match verbatim (task 1.7 brief: "same pattern the Python prototype
///      used"). This falls out of using the raw syscall directly; no
///      special-casing of "is this path a FIFO" is needed anywhere in this
///      type, matching Python's `open()`, which doesn't special-case it
///      either.
///   2. Legacy `FileHandle.write(_:)` raises an uncatchable Objective-C
///      exception (crashing the process) if the peer closes the pipe out
///      from under a write (`EPIPE`) -- there is no way to recover from
///      that with Swift `do/catch`. A regular file target on this task's
///      `--out video.h264` never hits `EPIPE`, but a FIFO target does the
///      moment the reader (`ffplay`) exits, and `stream.py`'s `emit()`
///      explicitly swallows exactly that (`except (BrokenPipeError,
///      ValueError): pass`) rather than crashing. Writing directly against
///      the fd with `write(2)` and checking `errno` lets this type match
///      that same graceful-degrade behavior instead of taking the process
///      down.
final class OutputSink {
    private let fd: Int32
    private(set) var broken = false

    /// Opens (creating/truncating a regular file, or blocking until a
    /// reader attaches for a FIFO) `path` for writing.
    init(path: String) throws {
        let opened = path.withCString { cpath in
            open(cpath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard opened >= 0 else {
            throw GVCLIError.message("Failed to open \(path) for writing: \(String(cString: strerror(errno)))")
        }
        self.fd = opened
    }

    /// Writes every byte of `data`, looping past short writes and EINTR.
    /// If the peer has gone away (`EPIPE`) or the sink is already marked
    /// `broken`, this silently no-ops -- matching `stream.py`'s `emit()`.
    func write(_ data: Data) {
        guard !broken, !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    // EPIPE (reader gone) or any other write error: stop
                    // trying for the rest of this sink's lifetime, same as
                    // Python's `except (BrokenPipeError, ValueError): pass`.
                    broken = true
                    return
                }
                offset += n
            }
        }
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
    }

    deinit {
        close()
    }
}

enum GVCLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let s): return s
        }
    }
}
