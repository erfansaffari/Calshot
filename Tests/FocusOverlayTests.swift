import XCTest
import AppKit
import ImageIO
@testable import Calshot

final class FocusOverlayTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    private func mark(_ points: [CGPoint], kind: FocusMark.Kind = .stroke, display: CGDirectDisplayID = 1,
                      time: TimeInterval = 0) -> FocusMark {
        FocusMark(kind: kind, points: points, displayID: display, timestamp: Date(timeIntervalSince1970: time))
    }

    func testCoordinatesAtOneX() {
        XCTAssertEqual(FocusFrameGeometry.pixelPoint(CGPoint(x: 25, y: 80), displayFrame: frame,
                                                    pixelSize: frame.size), CGPoint(x: 25, y: 20))
    }
    func testCoordinatesAtTwoX() {
        XCTAssertEqual(FocusFrameGeometry.pixelPoint(CGPoint(x: 25, y: 80), displayFrame: frame,
                                                    pixelSize: CGSize(width: 200, height: 200)), CGPoint(x: 50, y: 40))
    }
    func testNegativeAndOffsetDisplayOrigins() {
        let display = CGRect(x: -1600, y: 300, width: 1600, height: 900)
        XCTAssertEqual(FocusFrameGeometry.pixelPoint(CGPoint(x: -1500, y: 1000), displayFrame: display,
                                                    pixelSize: CGSize(width: 3200, height: 1800)), CGPoint(x: 200, y: 400))
        XCTAssertEqual(FocusFrameGeometry.pixelPoint(CGPoint(x: -1600, y: 1200), displayFrame: display,
                                                    pixelSize: CGSize(width: 1600, height: 900)), .zero)
    }
    func testNormalizedPointRegionIsPaddedAndClamped() {
        let point = mark([CGPoint(x: 0, y: 100)], kind: .point)
        let region = FocusFrameGeometry.region(for: point, displayFrame: frame, pixelSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(region, CGRect(x: 0, y: 0, width: 0.19, height: 0.19))
        XCTAssertEqual(region, FocusFrameGeometry.region(for: point, displayFrame: frame, pixelSize: frame.size))
    }
    func testStrokeRegionAndOutsideMark() {
        let stroke = mark([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)])
        let box = FocusFrameGeometry.region(for: stroke, displayFrame: frame, pixelSize: frame.size)
        XCTAssertEqual(box.minX, 0.06, accuracy: 0.0001)
        XCTAssertEqual(box.minY, 0.16, accuracy: 0.0001)
        XCTAssertEqual(box.width, 0.68, accuracy: 0.0001)
        XCTAssertEqual(box.height, 0.68, accuracy: 0.0001)
        XCTAssertEqual(FocusFrameGeometry.region(for: mark([CGPoint(x: -100, y: -100)]), displayFrame: frame, pixelSize: frame.size), .zero)
        XCTAssertEqual(FocusFrameGeometry.region(for: mark([]), displayFrame: frame, pixelSize: frame.size), .zero)
    }
    func testDownscalePreservesAspectAndNeverUpscales() {
        for size in [CGSize(width: 3840, height: 2160), CGSize(width: 2160, height: 3840), CGSize(width: 500, height: 500), CGSize(width: 2001, height: 1000)] {
            let result = FocusFrameGeometry.downscaledSize(size)
            XCTAssertLessThanOrEqual(max(result.width, result.height), 1280)
            XCTAssertLessThanOrEqual(result.width, size.width)
            XCTAssertEqual(result.width / result.height, size.width / size.height, accuracy: 0.003)
        }
        XCTAssertEqual(FocusFrameGeometry.downscaledSize(.zero), .zero)
    }
    func testClickAndDragThresholdUsesExcursionNotFinalDisplacement() {
        XCTAssertEqual(FocusMark.classify([.zero, CGPoint(x: 3.9, y: 0)]), .point)
        XCTAssertEqual(FocusMark.classify([.zero, CGPoint(x: 4, y: 0)]), .stroke)
        XCTAssertEqual(FocusMark.classify([.zero, CGPoint(x: 8, y: 0), .zero]), .stroke)
        XCTAssertEqual(FocusMark.classify([]), .point)
    }
    func testSmoothingRetainsEndpointsAndBounds() {
        let points = [CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 40), CGPoint(x: 60, y: 30)]
        let path = FocusInk.path(points: points, kind: .stroke)
        var start: CGPoint?
        var curves = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { start = element.pointee.points[0] }
            if element.pointee.type == .addQuadCurveToPoint { curves += 1 }
        }
        XCTAssertEqual(start, points.first)
        XCTAssertEqual(path.currentPoint, points.last)
        XCTAssertEqual(curves, 2)
        XCTAssertTrue(CGRect(x: 10, y: 20, width: 50, height: 20).contains(path.boundingBoxOfPath))
    }
    func testReduceMotionDisablesAllAnimationKinds() {
        for kind in [FocusMark.Kind.point, .stroke] {
            XCTAssertTrue(FocusInk.animationKeys(kind: kind, reduceMotion: true).isEmpty)
            XCTAssertTrue(FocusInk.animationKeys(kind: kind, reduceMotion: false).contains("settle"))
        }
        XCTAssertTrue(FocusInk.animationKeys(kind: .point, reduceMotion: false).contains("pulse"))
        XCTAssertTrue(FocusInk.animationKeys(kind: .stroke, reduceMotion: false).contains("draw"))
    }

    private func image(width: Int = 100, height: Int = 100) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    func testRenderingChangesOnlyExpectedTopLeftRegion() throws {
        let base = try image()
        for kind in [FocusMark.Kind.point, .stroke] {
            let points = kind == .point ? [CGPoint(x: 30, y: 80)] : [CGPoint(x: 25, y: 80), CGPoint(x: 40, y: 75)]
            let result = try FocusFrameGeometry.render(image: base, marks: [mark(points, kind: kind)], displayFrame: frame)
            let before = try pixels(base), after = try pixels(result)
            var changed = 0
            for y in 0..<100 {
                for x in 0..<100 {
                    let offset = (y * 100 + x) * 4
                    if Array(before[offset..<offset + 4]) != Array(after[offset..<offset + 4]) {
                        changed += 1
                        XCTAssertTrue((5...60).contains(x) && (0...45).contains(y), "Unexpected ink at \(x),\(y)")
                    }
                }
            }
            XCTAssertGreaterThan(changed, 20)
        }
    }
    func testJPEGDecodesToDownscaledSize() throws {
        let result = try FocusFrameGeometry.render(image: image(width: 2000, height: 1000), marks: [],
                                                   displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        let data = try FocusFrameGeometry.jpeg(image: result)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 1280); XCTAssertEqual(decoded.height, 640)
    }
    @MainActor func testExclusionIncludesAllOwnWindowsAndLocalFallback() {
        struct FakeContent: FocusWindowInventory {
            let focusWindows = [FocusCaptureWindow(id: 101, processID: 42), FocusCaptureWindow(id: 102, processID: 42),
                                FocusCaptureWindow(id: 103, processID: 42), FocusCaptureWindow(id: 201, processID: 77),
                                FocusCaptureWindow(id: 104, processID: nil)]
        }
        // Fictional overlay/notch/workspace IDs, including a window with no SCK owner metadata.
        XCTAssertEqual(FocusFrameComposer.excludedWindowIDs(in: FakeContent(), processID: 42, localWindowIDs: [104, 105]),
                       [101, 102, 103, 104, 105])
    }
    @MainActor func testDisplaySelectionPrefersLatestMarkThenExplicitThenPointer() {
        let marks = [mark([.zero], display: 1, time: 1), mark([.zero], display: 2, time: 2)]
        XCTAssertEqual(FocusFrameComposer.selectDisplay(marks: marks, available: [1, 2], preferred: 1, pointer: 1, main: 1), 2)
        XCTAssertEqual(FocusFrameComposer.selectDisplay(marks: [], available: [1, 2], preferred: 2, pointer: 1, main: 1), 2)
        XCTAssertEqual(FocusFrameComposer.selectDisplay(marks: marks, available: [3], preferred: nil, pointer: 3, main: 1), 3)
        XCTAssertNil(FocusFrameComposer.selectDisplay(marks: [], available: [], preferred: nil, pointer: nil, main: nil))
    }
    @MainActor func testInactiveLifecycleIsIdempotentAndDoesNotCreateWindows() {
        let overlay = FocusOverlayController()
        var changes = 0
        overlay.onMarksChanged = { _ in changes += 1 }
        overlay.setDrawing(true)
        XCTAssertFalse(overlay.isActive); XCTAssertFalse(overlay.isDrawing)
        overlay.clearMarks(); overlay.end(); overlay.end()
        XCTAssertTrue(overlay.marks.isEmpty); XCTAssertEqual(changes, 1)
    }
}
