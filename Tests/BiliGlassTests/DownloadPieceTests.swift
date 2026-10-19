import BiliNetworking
import Foundation
import Testing
@testable import BiliGlass

private actor PieceFixture: HTTPRangeStreaming {
  var ranges: [HTTPByteRange] = []
  var interrupted = false
  let pause: Bool
  init(pause: Bool = false) { self.pause = pause }
  func stream(from url: URL, rangeHeader: String, expectedRange r: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool, onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> HTTPRangeStreamResult {
    ranges.append(r)
    try await onResponse(HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: r.start,
      endInclusive: r.endInclusive, completeLength: expectedCompleteLength), contentLength: r.length,
      contentType: "video/mp4"))
    if !interrupted {
      interrupted = true
      try await onChunk(Data((r.start..<(r.start + 100)).map { UInt8($0 % 251) }))
      if pause { try await Task.sleep(for: .seconds(30)) }
      throw HTTPRangeResponseError.transport(errorType: "fixtureDisconnect")
    }
    try await onChunk(Data((r.start...r.endInclusive).map { UInt8($0 % 251) }))
    return HTTPRangeStreamResult(byteCount: r.length)
  }
}
@Suite struct DownloadPieceTests {
  @Test func interruptedDownloadOnlyRequestsMissingBytes() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("0.part")
    let fixture = PieceFixture()
    let range = try HTTPByteRange(start: 1000, endInclusive: 2_100_000)
    try await DownloadPiece.fetch(URL(string: "https://fixture.test/video")!, range: range,
      total: 3_000_000, target: target, transport: fixture) { _ in }
    #expect(try Data(contentsOf: target) == Data((range.start...range.endInclusive).map { UInt8($0 % 251) }))
    #expect(await fixture.ranges.filter { $0.start == 1000 }.count == 1)
    #expect(await fixture.ranges.contains { $0.start == 1100 })
    #expect(await fixture.ranges.allSatisfy { $0.length <= 1_048_576 })
  }
  @Test func pauseKeepsPrefixAndResumeUsesIt() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("0.part")
    let fixture = PieceFixture(pause: true)
    let range = try HTTPByteRange(start: 0, endInclusive: 999)
    let task = Task {
      try await DownloadPiece.fetch(URL(string: "https://fixture.test/video")!, range: range,
        total: 1000, target: target, transport: fixture) { _ in }
    }
    for _ in 0..<100 {
      if await fixture.interrupted { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let partial = try Data(contentsOf: target.appendingPathExtension("partial"))
    #expect(partial == Data((0..<100).map { UInt8($0 % 251) }))
    try await DownloadPiece.fetch(URL(string: "https://fixture.test/video")!, range: range,
      total: 1000, target: target, transport: fixture) { _ in }
    #expect(try Data(contentsOf: target) == Data((0..<1000).map { UInt8($0 % 251) }))
    #expect(await fixture.ranges.last?.start == 100)
  }
}
