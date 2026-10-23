import BiliNetworking
import Foundation
import Testing
@testable import BiliGlass

private actor DiskFixture: HTTPRangeStreaming {
  var calls: [HTTPByteRange] = []
  var active = 0, peak = 0
  let delay: Duration
  var interrupt: Bool
  init(delay: Duration = .milliseconds(15), interrupt: Bool = false) { self.delay = delay; self.interrupt = interrupt }
  func stream(from url: URL, rangeHeader: String, expectedRange r: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool, onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> HTTPRangeStreamResult {
    calls.append(r); active += 1; peak = max(peak, active); defer { active -= 1 }
    try await Task.sleep(for: delay)
    try await onResponse(HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: r.start,
      endInclusive: r.endInclusive, completeLength: expectedCompleteLength), contentLength: r.length, contentType: "video/mp4"))
    if interrupt {
      interrupt = false
      try await onChunk(Data((r.start..<(r.start + 100)).map { UInt8($0 % 251) }))
      throw CDNIdleTimeout()
    }
    try await onChunk(Data((r.start...r.endInclusive).map { UInt8($0 % 251) }))
    return HTTPRangeStreamResult(byteCount: r.length)
  }
}
private actor CacheOutput {
  var bytes = Data(), headers = 0
  func append(_ value: Data) { bytes.append(value) }
  func header() { headers += 1 }
}
private actor SlowPlayerConsumer {
  var entered = false
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}
private struct StartupChunkFixture: HTTPRangeStreaming {
  func stream(from url: URL, rangeHeader: String, expectedRange: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool, onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> HTTPRangeStreamResult {
    try await onResponse(HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: expectedRange.start,
      endInclusive: expectedRange.endInclusive, completeLength: expectedCompleteLength),
      contentLength: expectedRange.length, contentType: "video/mp4"))
    try await onChunk(Data(repeating: 7, count: 64))
    try await Task.sleep(for: .seconds(30))
    throw CDNIdleTimeout()
  }
}
@Suite struct PlaybackDiskCacheTests {
  let url = URL(string: "https://fixture.test/media?secret=not-for-disk")!
  func read(_ cache: PlaybackDiskCache, _ start: Int64, _ end: Int64, length: Int64) async throws -> Data {
    let range = try HTTPByteRange(start: start, endInclusive: end), output = CacheOutput()
    _ = try await cache.stream(from: url, rangeHeader: range.headerValue, expectedRange: range,
      expectedCompleteLength: length, headers: [:], allowedContentTypes: ["video/mp4"], requiresContentLength: true,
      onResponse: { _ in await output.header() }, onChunk: { await output.append($0) })
    #expect(await output.headers == 1)
    return await output.bytes
  }
  @Test func startupReadsOnlyRequestedBytesThenPrefetchesFromResumePosition() async throws {
    let source = DiskFixture(), page = PlaybackDiskCache.pageSize, length = page * 4
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try PlaybackDiskCache(source: source, videoURLs: [url], connections: 1,
      reserveSpace: 0, streamDuringStartup: true, root: root)
    _ = try await read(cache, 0, 127, length: length)
    _ = try await read(cache, 2 * page + 100, 2 * page + 199, length: length)
    let startup = await source.calls
    #expect(startup.map(\.length) == [128, 100])
    #expect(await cache.statistics()["diskCacheBytes"] == 0)
    await cache.start()
    for _ in 0..<300 {
      if await cache.statistics()["diskCacheComplete"] == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await source.calls.dropFirst(2).map(\.start) == [2 * page, 3 * page, 0, page])
    #expect(await cache.statistics()["diskCacheComplete"] == 1)
    let calls = await source.calls.count
    #expect(try await read(cache, 2 * page + 100, 2 * page + 199, length: length).count == 100)
    #expect(await source.calls.count == calls)
    await cache.stop(); try? FileManager.default.removeItem(at: root)
  }
  @Test func startupDeliversChunksBeforeWholeRangeAndCancelsOnSwitch() async throws {
    let output = CacheOutput()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try PlaybackDiskCache(source: StartupChunkFixture(), videoURLs: [url], connections: 2,
      reserveSpace: 0, streamDuringStartup: true, root: root)
    let request = Task {
      let range = try HTTPByteRange(start: 0, endInclusive: 999)
      return try await cache.stream(from: url, rangeHeader: range.headerValue, expectedRange: range,
        expectedCompleteLength: 2_000_000, headers: [:], allowedContentTypes: ["video/mp4"],
        requiresContentLength: true, onResponse: { _ in await output.header() },
        onChunk: { await output.append($0) })
    }
    for _ in 0..<100 {
      if await output.bytes.count == 64 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await output.bytes.count == 64)
    #expect(await output.headers == 1)
    await cache.stop()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(!FileManager.default.fileExists(atPath: await cache.directory.path))
    try? FileManager.default.removeItem(at: root)
  }
  @Test func prefetchContinuesToEndAndServesPartialRangesWithoutAnotherDownload() async throws {
    let source = DiskFixture(), length: Int64 = 2_300_000
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try PlaybackDiskCache(source: source, videoURLs: [url], connections: 4, reserveSpace: 0, root: root)
    let directory = await cache.directory
    let first = try await read(cache, 500, 599, length: length)
    #expect(first == Data((500...599).map { UInt8($0 % 251) }))
    await cache.start()
    for _ in 0..<200 {
      if await cache.statistics()["diskCacheComplete"] == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await cache.statistics()["diskCacheComplete"] == 1)
    #expect(await cache.statistics()["diskCacheBytes"] == Int(length))
    let calls = await source.calls.count
    let tail = try await read(cache, 1_048_570, 1_048_590, length: length)
    #expect(tail == Data((1_048_570...1_048_590).map { UInt8($0 % 251) }))
    #expect(await source.calls.count == calls)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains("secret") })
    PlaybackTemporaryFiles.cleanup(root: root)
    #expect(FileManager.default.fileExists(atPath: directory.path)) // Active lease must survive cleanup.
    await cache.stop()
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    try? FileManager.default.removeItem(at: root)
  }
  @Test func twentyFourReadAheadLanesAreUsedWithoutExceedingTheSetting() async throws {
    let source = DiskFixture(delay: .milliseconds(80)), length: Int64 = 26 * 1_048_576
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try PlaybackDiskCache(source: source, videoURLs: [url], connections: 24, reserveSpace: 0, root: root)
    _ = try await read(cache, 0, 99, length: length)
    await cache.start()
    for _ in 0..<200 {
      if await source.peak >= 24 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await source.peak == 24)
    #expect(await cache.statistics()["configuredConnections"] == 24)
    await cache.stop(); try? FileManager.default.removeItem(at: root)
  }
  @Test func concurrentOverlappingRequestsShareNetworkPagesAndHonorConnectionLimit() async throws {
    let source = DiskFixture(), length: Int64 = 4_300_000
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try PlaybackDiskCache(source: source, videoURLs: [url], connections: 2, reserveSpace: 0, root: root)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<12 { group.addTask { _ = try await read(cache, Int64(i % 4) * 1_048_576, Int64(i % 4) * 1_048_576 + 99, length: length) } }
      try await group.waitForAll()
    }
    #expect(await source.calls.count == 4)
    #expect(await source.peak <= 2)
    await cache.stop(); try? FileManager.default.removeItem(at: root)
  }
  @Test func storageLimitDoesNotPreventPlaybackAndStopCancelsReadAhead() async throws {
    let source = DiskFixture(), length: Int64 = 3_300_000
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try PlaybackDiskCache(source: source, videoURLs: [url], connections: 2, capacity: 1_048_576, reserveSpace: 0, root: root)
    _ = try await read(cache, 0, 99, length: length)
    await cache.start()
    for _ in 0..<100 {
      if await cache.statistics()["diskCacheLimited"] == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await cache.statistics()["diskCacheLimited"] == 1)
    let before = await source.calls.count
    #expect(try await read(cache, 0, 99, length: length).count == 100)
    #expect(await source.calls.count == before)
    #expect(try await read(cache, 3_200_000, 3_200_099, length: length).count == 100)
    await cache.stop()
    let calls = await source.calls.count
    try await Task.sleep(for: .milliseconds(30))
    #expect(await source.calls.count == calls)
    #expect(!FileManager.default.fileExists(atPath: await cache.directory.path))
    try? FileManager.default.removeItem(at: root)
  }
  @Test func stopCancelsInflightTransferAndDeletesItsTemporaryDirectory() async throws {
    let source = DiskFixture(delay: .seconds(30))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try PlaybackDiskCache(source: source, videoURLs: [url], connections: 2, reserveSpace: 0, root: root)
    let request = Task { try await read(cache, 0, 99, length: 1_000_000) }
    for _ in 0..<100 {
      if await source.active > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    await cache.stop()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(await source.active == 0)
    #expect(!FileManager.default.fileExists(atPath: await cache.directory.path))
    try? FileManager.default.removeItem(at: root)
  }

  @Test func temporaryPageKeepsItsPrefixAcrossASlowNodeRetry() async throws {
    let source = DiskFixture(interrupt: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try PlaybackDiskCache(source: source, videoURLs: [url], connections: 2, reserveSpace: 0, root: root)
    let bytes = try await read(cache, 0, 999, length: 1000)
    #expect(bytes == Data((0..<1000).map { UInt8($0 % 251) }))
    #expect(await source.calls.map(\.start) == [0, 100])
    #expect(await cache.statistics()["retriedBlocks"] == 1)
    await cache.stop(); try? FileManager.default.removeItem(at: root)
  }

  @Test func readAheadContinuesWhilePlayerTemporarilyStopsConsuming() async throws {
    let source = DiskFixture(), consumer = SlowPlayerConsumer()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try PlaybackDiskCache(source: source, videoURLs: [url], connections: 4, reserveSpace: 0, root: root)
    let request = Task {
      let range = try HTTPByteRange(start: 0, endInclusive: 99)
      return try await cache.stream(from: url, rangeHeader: range.headerValue, expectedRange: range,
        expectedCompleteLength: 2_300_000, headers: [:], allowedContentTypes: ["video/mp4"], requiresContentLength: true,
        onResponse: { _ in }, onChunk: { _ in await consumer.wait() })
    }
    for _ in 0..<100 {
      if await consumer.entered { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await consumer.entered)
    await cache.start()
    for _ in 0..<100 {
      if await cache.statistics()["diskCacheComplete"] == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await cache.statistics()["diskCacheComplete"] == 1)
    await consumer.release()
    #expect(try await request.value.byteCount == 100)
    await cache.stop(); try? FileManager.default.removeItem(at: root)
  }

}
