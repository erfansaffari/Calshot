import AppKit
import WebKit
import ImageIO

/// Only capture IDs can be requested; the page cannot read arbitrary filesystem paths.
@MainActor
final class WebWorkspaceAssets: NSObject, WKURLSchemeHandler {
    let model: CalshotModel
    private var lastImage: NSImage?
    private var currentData: Data?
    private(set) var currentURL: String?
    private var stopped = Set<ObjectIdentifier>()
    private let thumbnails: NSCache<NSString, NSData> = { let cache = NSCache<NSString, NSData>(); cache.totalCostLimit = 16 * 1024 * 1024; return cache }()
    init(model: CalshotModel) { self.model = model }
    func refreshImage() {
        guard model.image !== lastImage else { return }
        lastImage = model.image
        guard let image = model.image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            currentData = nil; currentURL = nil; return
        }
        currentData = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.86])
        currentURL = currentData == nil ? nil : "calshot-asset://current/" + UUID().uuidString
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        stopped.remove(key)
        guard let url = urlSchemeTask.request.url, url.scheme == "calshot-asset" else { urlSchemeTask.didFailWithError(URLError(.badURL)); return }
        if url.host == "current", let data = currentData {
            respond(urlSchemeTask, data: data, mime: "image/jpeg"); return
        }
        if url.host == "proposal", let id = UUID(uuidString: url.lastPathComponent),
           let proposal = model.calendarActions.proposals.first(where: { $0.id == id }),
           let image = model.sourceImage(for: proposal), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.86]) {
            respond(urlSchemeTask, data: data, mime: "image/jpeg"); return
        }
        guard url.host == "memory", let id = UUID(uuidString: url.lastPathComponent),
              let record = model.memoryRecords.first(where: { $0.id == id }) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let cacheKey = id.uuidString as NSString
        if let cached = thumbnails.object(forKey: cacheKey) {
            respond(urlSchemeTask, data: cached as Data, mime: "image/jpeg"); return
        }
        let store = model.memoryStore
        Task { [weak self] in
            let data = await Task.detached { () -> Data? in
                guard let original = store.imageData(for: record, sourceID: record.additionalScreenshots?.last?.id),
                      let source = CGImageSourceCreateWithData(original as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            }.value
            guard let self, self.stopped.remove(key) == nil else { return }
            guard let data else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
            self.thumbnails.setObject(data as NSData, forKey: cacheKey, cost: data.count)
            self.respond(urlSchemeTask, data: data, mime: "image/jpeg")
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { stopped.insert(ObjectIdentifier(urlSchemeTask)) }
    private func respond(_ task: any WKURLSchemeTask, data: Data, mime: String) {
        task.didReceive(URLResponse(url: task.request.url!, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data); task.didFinish()
    }
}
