import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

struct FocusFrame: Sendable {
    let jpegData: Data
    let pixelSize: CGSize
    let displayID: CGDirectDisplayID
    /// Padded bounds, top-left origin, normalized to the returned image. Only marks on this display.
    let regions: [CGRect]
    let capturedAt: Date
    /// On-device text recognition of the full-resolution capture. Untrusted screen content, never instructions.
    var screenText: ScreenTextRecognition? = nil
}

enum FocusFrameError: Error, LocalizedError {
    case screenRecordingPermissionMissing
    case noDisplays
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionMissing: return "Allow Screen Recording for Calshot in System Settings, then try again."
        case .noDisplays: return "No screen is available to capture. Reconnect a display and try again."
        case .captureFailed: return "The screen frame could not be captured. Try again."
        }
    }
}

struct FocusCaptureWindow {
    let id: CGWindowID
    let processID: pid_t?
}

protocol FocusWindowInventory {
    var focusWindows: [FocusCaptureWindow] { get }
}

extension SCShareableContent: FocusWindowInventory {
    var focusWindows: [FocusCaptureWindow] {
        windows.map { FocusCaptureWindow(id: $0.windowID, processID: $0.owningApplication?.processID) }
    }
}

/// No timers, persistence or network access. Step D requests one frame per turn/drawing.
@MainActor
final class FocusFrameComposer {
    func captureFrame(marks: [FocusMark], preferredDisplayID: CGDirectDisplayID? = nil) async throws -> FocusFrame {
        guard CGPreflightScreenCaptureAccess() else { throw FocusFrameError.screenRecordingPermissionMissing }
        do {
            try Task.checkCancellation()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let screens = NSScreen.screens
            let ids = content.displays.map(\.displayID)
            let pointerID = screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.focusDisplayID
            guard let id = Self.selectDisplay(marks: marks, available: ids, preferred: preferredDisplayID,
                                             pointer: pointerID, main: NSScreen.main?.focusDisplayID),
                  let display = content.displays.first(where: { $0.displayID == id }),
                  let screen = screens.first(where: { $0.focusDisplayID == id }) else { throw FocusFrameError.noDisplays }
            let ownIDs = Self.excludedWindowIDs(in: content, processID: ProcessInfo.processInfo.processIdentifier,
                                               localWindowIDs: Set(NSApp.windows.compactMap { $0.windowNumber > 0 ? CGWindowID(exactly: $0.windowNumber) : nil }))
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            // Application exclusion also covers windows created while the async screenshot is pending.
            let filter = ownApps.isEmpty
                ? SCContentFilter(display: display, excludingWindows: content.windows.filter { ownIDs.contains($0.windowID) })
                : SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try Task.checkCancellation()
            let capturedAt = Date()
            let selected = marks.filter { $0.displayID == id }
            let displayFrame = screen.frame
            // Composite/encode and text recognition run concurrently off the main actor, so a capture
            // started while the user talks never stalls microphone delivery or the notch.
            async let encoded = Task.detached(priority: .userInitiated) {
                let composed = try FocusFrameGeometry.render(image: image, marks: selected, displayFrame: displayFrame)
                return (CGSize(width: composed.width, height: composed.height), try FocusFrameGeometry.jpeg(image: composed))
            }.value
            // Read text from the full-resolution capture; the 1280 px frame is too small for exact dates in an email.
            let text = try? await ScreenTextRecognizer.recognizeLayout(in: image)
            let (size, jpeg) = try await encoded
            try Task.checkCancellation()
            return FocusFrame(jpegData: jpeg, pixelSize: size, displayID: id,
                              regions: selected.map { FocusFrameGeometry.region(for: $0, displayFrame: screen.frame, pixelSize: size) },
                              capturedAt: capturedAt, screenText: text)
        } catch is CancellationError { throw CancellationError() }
        catch let error as FocusFrameError { throw error }
        catch {
            if !CGPreflightScreenCaptureAccess() { throw FocusFrameError.screenRecordingPermissionMissing }
            throw FocusFrameError.captureFailed
        }
    }

    static func excludedWindowIDs(in inventory: any FocusWindowInventory, processID: pid_t,
                                  localWindowIDs: Set<CGWindowID>) -> Set<CGWindowID> {
        localWindowIDs.union(inventory.focusWindows.filter { $0.processID == processID }.map(\.id))
    }

    static func selectDisplay(marks: [FocusMark], available: [CGDirectDisplayID], preferred: CGDirectDisplayID?,
                              pointer: CGDirectDisplayID?, main: CGDirectDisplayID?) -> CGDirectDisplayID? {
        let marked = marks.filter { available.contains($0.displayID) }.max { $0.timestamp < $1.timestamp }?.displayID
        return [marked, preferred, pointer, main].compactMap { $0 }.first { available.contains($0) } ?? available.first
    }
}

extension NSScreen {
    var focusDisplayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}

/// All image coordinates use a top-left origin; AppKit global points use bottom-left.
enum FocusFrameGeometry {
    static func pixelPoint(_ point: CGPoint, displayFrame: CGRect, pixelSize: CGSize) -> CGPoint {
        CGPoint(x: (point.x - displayFrame.minX) * pixelSize.width / displayFrame.width,
                y: (displayFrame.maxY - point.y) * pixelSize.height / displayFrame.height)
    }

    static func downscaledSize(_ size: CGSize, maximumEdge: CGFloat = 1280) -> CGSize {
        guard size.width > 0, size.height > 0, maximumEdge >= 1 else { return .zero }
        let ratio = min(1, maximumEdge / max(size.width, size.height))
        return CGSize(width: max(1, floor(size.width * ratio)), height: max(1, floor(size.height * ratio)))
    }

    static func region(for mark: FocusMark, displayFrame: CGRect, pixelSize: CGSize, padding: CGFloat = 12) -> CGRect {
        guard !mark.points.isEmpty, displayFrame.width > 0, displayFrame.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        // Padding is in screen points, independent of capture resolution and Retina scale.
        let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
        let radius = padding + (mark.kind == .point ? 7 : 2)
        let bounds = CGRect(x: xs.min()! - radius, y: ys.min()! - radius,
                            width: xs.max()! - xs.min()! + radius * 2, height: ys.max()! - ys.min()! + radius * 2)
        let clipped = bounds.intersection(displayFrame)
        guard !clipped.isNull else { return .zero }
        let top = pixelPoint(CGPoint(x: clipped.minX, y: clipped.maxY), displayFrame: displayFrame, pixelSize: pixelSize)
        return CGRect(x: top.x / pixelSize.width, y: top.y / pixelSize.height,
                      width: clipped.width / displayFrame.width, height: clipped.height / displayFrame.height)
    }

    static func render(image: CGImage, marks: [FocusMark], displayFrame: CGRect) throws -> CGImage {
        let size = downscaledSize(CGSize(width: image.width, height: image.height))
        guard displayFrame.width > 0, displayFrame.height > 0,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FocusFrameError.captureFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let scale = size.width / displayFrame.width
        context.setLineCap(.round); context.setLineJoin(.round)
        for mark in marks where !mark.points.isEmpty {
            let points = mark.points.map { pixelPoint($0, displayFrame: displayFrame, pixelSize: size) }
            let path = FocusInk.path(points: points, kind: mark.kind, pointRadius: 7 * scale)
            context.saveGState()
            context.setShadow(offset: .zero, blur: 5 * scale, color: FocusInk.color.copy(alpha: 0.6))
            context.setStrokeColor(FocusInk.color); context.setLineWidth(max(2, 3 * scale))
            context.addPath(path); context.strokePath()
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw FocusFrameError.captureFailed }
        return result
    }

    static func jpeg(image: CGImage, quality: CGFloat = 0.7) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FocusFrameError.captureFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FocusFrameError.captureFailed }
        return data as Data
    }
}
