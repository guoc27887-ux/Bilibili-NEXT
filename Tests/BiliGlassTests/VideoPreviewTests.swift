import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BiliGlass

private final class PreviewIndexProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    #expect(request.url?.host == "i0.hdslb.com")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/octet-stream"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data([0, 0, 0, 5, 0, 10]))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private actor PendingPreviewImages {
  let started: AsyncStream<URL>.Continuation
  var pending: [URL: CheckedContinuation<PreviewSheet, Error>] = [:]
  init(started: AsyncStream<URL>.Continuation) { self.started = started }
  func load(_ url: URL) async throws -> PreviewSheet {
    try await withCheckedThrowingContinuation { continuation in
      pending[url] = continuation; started.yield(url)
    }
  }
  func complete(_ url: URL, image: CGImage) { pending.removeValue(forKey: url)?.resume(returning: PreviewSheet(image: image)) }
  func fail(_ url: URL) { pending.removeValue(forKey: url)?.resume(throwing: URLError(.cancelled)) }
}

struct VideoPreviewTests {
  @Test @MainActor func missingJSONIndexLoadsTheAdvertisedBinaryWithoutCredentials() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PreviewIndexProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config))
    api.cookies = ["SESSDATA": "fixture", "bili_jct": "fixture-csrf"]
    let shots = try await api.previewShots(data: ["pvdata": "//i0.hdslb.com/preview.bin",
      "image": ["//i0.hdslb.com/sheet.jpg"], "img_x_len": 10, "img_y_len": 10,
      "img_x_size": 480, "img_y_size": 270], cid: 42)
    #expect(shots.times == [0, 5, 10]); #expect(shots.frame(at: 7)?.index == 1)
    let legacy = try await api.previewShots(data: ["index": [0, 4, 8],
      "image": ["//i0.hdslb.com/sheet.jpg"], "img_x_len": 10, "img_y_len": 10], cid: 42)
    #expect(legacy.times == [0, 4, 8])
  }
  @Test func binaryTimestampIndexUsesBigEndianSecondsAndRejectsTruncation() throws {
    #expect(try VideoShots.binaryTimes(Data([0, 0, 0, 5, 0, 10, 1, 44])) == [0, 5, 10, 300])
    #expect(throws: BiliError.self) { try VideoShots.binaryTimes(Data([0, 0, 1])) }
    #expect(throws: BiliError.self) { try VideoShots.binaryTimes(Data([0, 10, 0, 5])) }
  }
  private func sheet(width: Int = 40, height: Int = 20) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
  }
  @Test @MainActor func cancelledOldHoverCannotClearNewImageAfterSharedDownloadCompletes() async throws {
    let (events, started) = AsyncStream<URL>.makeStream()
    let loader = PendingPreviewImages(started: started)
    let model = VideoPreviewModel(loadSheet: { try await loader.load($0) })
    var iterator = events.makeAsyncIterator()
    let a = URL(string: "https://i0.hdslb.com/old.jpg")!, b = URL(string: "https://i0.hdslb.com/new.jpg")!
    let old = Task { await model.load(.init(url: a, index: 0, columns: 1, rows: 1)) }
    #expect(await iterator.next() == a)
    let new = Task { await model.load(.init(url: b, index: 0, columns: 1, rows: 1)) }
    #expect(await iterator.next() == b)
    let image = try sheet()
    await loader.complete(b, image: image); await new.value
    #expect(model.image != nil)
    old.cancel(); await loader.fail(a); await old.value
    #expect(model.image != nil); #expect(!model.unavailable); #expect(!model.loading)
  }
  @Test func partialFinalSpriteUsesAdvertisedCellSize() throws {
    // The final sheet contains one row, although the nominal grid has ten rows.
    let image = PreviewSheet(image: try sheet(width: 40, height: 20))
    let frame = VideoPreviewFrame(url: URL(string: "https://i0.hdslb.com/last.jpg")!, index: 1,
      columns: 2, rows: 10, cellWidth: 20, cellHeight: 20)
    let crop = try frame.crop(image)
    #expect(crop.width == 20); #expect(crop.height == 20)
    let absent = VideoPreviewFrame(url: frame.url, index: 2, columns: 2, rows: 10, cellWidth: 20, cellHeight: 20)
    #expect(throws: BiliError.self) { try absent.crop(image) }
  }
  @Test @MainActor func failedImageLeavesTimeOnlyStateInsteadOfBlankPicture() async {
    let model = VideoPreviewModel(loadSheet: { _ in throw URLError(.timedOut) })
    await model.load(.init(url: URL(string: "https://i0.hdslb.com/missing.jpg")!, index: 0, columns: 1, rows: 1))
    #expect(model.unavailable); #expect(model.image == nil); #expect(!model.loading)
  }
  @Test func previewFramesCrossSheetsAndRejectUnavailableCells() throws {
    let a = URL(string: "https://i0.hdslb.com/first.jpg")!, b = URL(string: "https://i0.hdslb.com/second.jpg")!
    let shots = VideoShots(times: [0, 5, 10, 15, 20], urls: [a, b], columns: 2, rows: 2, cellWidth: 20, cellHeight: 20)
    #expect(shots.frame(at: 19)?.url == a); #expect(shots.frame(at: 19)?.index == 3)
    #expect(shots.frame(at: 20)?.url == b); #expect(shots.frame(at: 20)?.index == 0)
    #expect(shots.frame(at: .nan) == nil)
  }
  @Test func largeSheetsStayWithinDecodedCacheBudgetAndCropAtScaledCoordinates() async throws {
    let source = try sheet(width: 2600, height: 2600)
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, source, nil); #expect(CGImageDestinationFinalize(destination))
    let decoded = try await PreviewSheets.decode(data as Data)
    #expect(decoded.sourceWidth == 2600); #expect(decoded.width == 2400)
    #expect(decoded.image.bytesPerRow * decoded.height < 32 * 1024 * 1024)
    let frame = VideoPreviewFrame(url: URL(string: "https://i0.hdslb.com/sheet.jpg")!, index: 99,
      columns: 10, rows: 10, cellWidth: 260, cellHeight: 260)
    let crop = try frame.crop(decoded)
    #expect(crop.width == 240); #expect(crop.height == 240)
  }
}
