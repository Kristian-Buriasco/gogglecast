import Foundation
import AppKit
import CoreImage

enum Screenshot {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/GogglesView", isDirectory: true)
    }

    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "GogglesView-\(f.string(from: date)).png"
    }

    /// Puts the frame on the pasteboard as PNG and TIFF (same untransformed
    /// frame `save` writes), so any app can paste it. Replaces the contents.
    static func copyFrameToPasteboard(_ pixelBuffer: CVPixelBuffer, pasteboard: NSPasteboard = .general) throws {
        let rep = NSBitmapImageRep(ciImage: CIImage(cvPixelBuffer: pixelBuffer))
        guard let png = rep.representation(using: .png, properties: [:]),
              let tiff = rep.tiffRepresentation else {
            throw CocoaError(.fileWriteUnknown)
        }
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png), pasteboard.setData(tiff, forType: .tiff) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @discardableResult
    static func save(_ pixelBuffer: CVPixelBuffer, date: Date = Date()) throws -> URL {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let rep = NSBitmapImageRep(ciImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = UniqueFileURL.reserve(directory.appendingPathComponent(fileName(for: date)))
        try png.write(to: url)
        return url
    }
}
