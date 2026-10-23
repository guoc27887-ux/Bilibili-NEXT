import BiliNetworking
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BiliGlass

@Suite struct MemoryLoadingTests {
  @Test func pagePrefixIsOnDiskBeforeDownloadCompletesAndOnlyPublishesExactLength() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let page = root.appendingPathComponent("fixture.page")
    let writer = try DiskPageWriter(file: page)
    defer { writer.close() }
    let range = try HTTPByteRange(start: 0, endInclusive: 999)
    try writer.header(HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: 0, endInclusive: 999, completeLength: 1000), contentLength: range.length, contentType: "video/mp4"))
    try writer.append(Data(repeating: 7, count: 100))
    #expect(writer.byteCount == 100)
    #expect(!FileManager.default.fileExists(atPath: page.path))
    #expect(try Data(contentsOf: page.appendingPathExtension("partial")).count == 100)
    #expect(throws: (any Error).self) { try writer.complete(length: 1000) }
    try writer.append(Data(repeating: 8, count: 900))
    _ = try writer.complete(length: 1000)
    #expect(try Data(contentsOf: page) == Data(repeating: 7, count: 100) + Data(repeating: 8, count: 900))
    #expect(!FileManager.default.fileExists(atPath: page.appendingPathExtension("partial").path))
  }
  @Test func cancelledPageClosesAndDeletesUnpublishedPrefix() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let page = root.appendingPathComponent("fixture.page")
    let writer = try DiskPageWriter(file: page)
    try writer.append(Data(repeating: 1, count: 100))
    writer.close()
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    #expect(throws: (any Error).self) { try writer.append(Data([1])) }
  }
  @Test func avatarsDecodeAtDisplaySizeInsteadOfRetainingFullCoverSizedBitmaps() async throws {
    let context = try #require(CGContext(data: nil, width: 1200, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let original = try #require(context.makeImage())
    let data = NSMutableData()
    let encoder = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(encoder, original, nil)
    #expect(CGImageDestinationFinalize(encoder))
    let small = try await ThumbnailCache.decode(data as Data, maxPixelSize: 96)
    let cover = try await ThumbnailCache.decode(data as Data, maxPixelSize: 800)
    #expect(small.width == 128 && small.height == 128)
    #expect(cover.width == 900 && cover.height == 900)
    #expect(small.bytesPerRow * small.height < cover.bytesPerRow * cover.height / 40)
  }
}
