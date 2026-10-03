import XCTest
@testable import GogglesView

final class ViewFramingTests: XCTestCase {
    func testCropRect() {
        let r = FramingGeometry.cropRect(in: CGSize(width: 1000, height: 1000), ratio: 16.0 / 9)
        XCTAssertEqual(r.width, 1000, accuracy: 0.01)
        XCTAssertEqual(r.height, 562.5, accuracy: 0.01)
        XCTAssertEqual(r.minY, 218.75, accuracy: 0.01)
        let sq = FramingGeometry.cropRect(in: CGSize(width: 1600, height: 900), ratio: 1)
        XCTAssertEqual(sq, CGRect(x: 350, y: 0, width: 900, height: 900))
        XCTAssertEqual(FramingGeometry.cropRect(in: CGSize(width: 10, height: 5), ratio: nil), CGRect(x: 0, y: 0, width: 10, height: 5))
    }

    func testZoomPanClamping() {
        XCTAssertEqual(FramingGeometry.clampZoom(0.2), 1)
        XCTAssertEqual(FramingGeometry.clampZoom(9), 4)
        XCTAssertEqual(FramingGeometry.clampPan(0.7, zoom: 1), 0)
        XCTAssertEqual(FramingGeometry.clampPan(3, zoom: 2), 1)
        // At max pan the picture edge meets the crop edge: shift = (z-1)*extent/2.
        XCTAssertEqual(FramingGeometry.offset(pan: 1, zoom: 3, extent: 100), 100, accuracy: 0.001)
        XCTAssertEqual(FramingGeometry.pan(0.9, dragging: 500, zoom: 2, extent: 100), 1)
        XCTAssertEqual(FramingGeometry.pan(0, dragging: 25, zoom: 2, extent: 100), 0.5, accuracy: 0.001)
        XCTAssertEqual(FramingGeometry.pan(0.5, dragging: 10, zoom: 1, extent: 100), 0)
    }

    func testGridLines() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 90)
        XCTAssertEqual(FramingGeometry.gridLines(in: rect, mode: .off).count, 0)
        let thirds = FramingGeometry.gridLines(in: rect, mode: .thirds)
        XCTAssertEqual(thirds.count, 4)
        XCTAssertEqual(thirds[0].0.x, 100, accuracy: 0.001)
        XCTAssertEqual(FramingGeometry.gridLines(in: rect, mode: .cross).count, 2)
    }
}
