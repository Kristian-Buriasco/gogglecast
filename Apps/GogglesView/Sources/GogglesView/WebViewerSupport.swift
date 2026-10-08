import Foundation
import Network
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Bonjour

/// The viewer is advertised as `_http._tcp` only while LAN access is on. The listener owns the
/// registration, so cancelling it (viewer off, LAN off, app quit) withdraws the service.
enum WebViewerBonjour {
    static let type = "_http._tcp"
    static let name = "GogglesView"

    static func service() -> NWListener.Service { NWListener.Service(name: name, type: type) }

    /// Pure rule: advertise only when the viewer is enabled and other devices are allowed.
    static func shouldAdvertise(enabled: Bool, allowLAN: Bool) -> Bool { enabled && allowLAN }
}

// MARK: - Addresses

enum WebViewerAddress {
    /// The IPv4 address to put in the QR code: private LAN ranges first (192.168, 10, 172.16-31),
    /// never loopback or link-local. nil when there is none.
    static func preferredIPv4(from addresses: [String]) -> String? {
        let v4 = addresses.compactMap { a -> (String, [Int])? in
            let p = a.split(separator: ".").compactMap { Int($0) }
            return p.count == 4 && p.allSatisfy({ (0...255).contains($0) }) && a.split(separator: ".").count == 4 ? (a, p) : nil
        }.filter { $0.1[0] != 127 && $0.1[0] != 0 && !($0.1[0] == 169 && $0.1[1] == 254) }
        func rank(_ p: [Int]) -> Int {
            if p[0] == 192 && p[1] == 168 { return 0 }
            if p[0] == 10 { return 1 }
            if p[0] == 172 && (16...31).contains(p[1]) { return 2 }
            return 3
        }
        return v4.enumerated().min { (rank($0.element.1), $0.offset) < (rank($1.element.1), $1.offset) }?.element.0
    }
}

// MARK: - QR code

enum WebViewerQR {
    /// A crisp (nearest-neighbour scaled) QR code of `text`, at least `minSide` pixels wide.
    static func image(for text: String, minSide: Int = 256) -> CGImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let modules = Int(out.extent.width)
        guard modules > 0 else { return nil }
        let scale = max(1, (minSide + modules - 1) / modules)
        let scaled = out.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        // Quiet zone of 4 modules, black on white.
        let pad = CGFloat(4 * scale)
        let padded = scaled.transformed(by: CGAffineTransform(translationX: pad, y: pad))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: scaled.extent.width + 2 * pad, height: scaled.extent.height + 2 * pad)))
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(padded, from: padded.extent)
    }
}

// MARK: - Home screen icon

enum WebViewerIcon {
    private static let cache = NSCache<NSNumber, NSData>()

    /// Dark rounded square with the orange dot, as PNG. Only the sizes the page references are served.
    static func png(size: Int) -> Data? {
        guard size == 180 || size == 512 else { return nil }
        if let d = cache.object(forKey: NSNumber(value: size)) { return d as Data }
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0x1a / 255, green: 0x16 / 255, blue: 0x12 / 255, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(srgbRed: 0xd9 / 255, green: 0x46 / 255, blue: 0x1f / 255, alpha: 1))
        let r = s * 0.2
        ctx.fillEllipse(in: CGRect(x: s / 2 - r, y: s / 2 - r, width: 2 * r, height: 2 * r))
        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        cache.setObject(out, forKey: NSNumber(value: size))
        return out as Data
    }
}
