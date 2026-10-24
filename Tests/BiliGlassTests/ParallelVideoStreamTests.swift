import BiliNetworking
import Foundation
import Testing

@testable import BiliGlass

private actor RangeFixture: HTTPRangeStreaming {
  var active = 0
  var peak = 0
  var ranges: [HTTPByteRange] = []
  let delay: Duration
  let uniform: Bool
  let earlyOutput: StreamOutput?
  var consumerSawPrefixBeforeEnd = false
  init(delay: Duration = .milliseconds(15), uniform: Bool = false, earlyOutput: StreamOutput? = nil) {
    self.delay = delay; self.uniform = uniform; self.earlyOutput = earlyOutput
  }
  func stream(
    from url: URL, rangeHeader: String, expectedRange: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool,
    onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> HTTPRangeStreamResult {
    active += 1
    peak = max(peak, active)
    ranges.append(expectedRange)
    defer { active -= 1 }
    try await Task.sleep(for: expectedRange.start == 0 ? delay * 3 : delay)
    let response = try HTTPRangeStreamResponse(
      contentRange: HTTPContentRange(
        start: expectedRange.start,
        endInclusive: expectedRange.endInclusive, completeLength: expectedCompleteLength),
      contentLength: expectedRange.length, contentType: "video/mp4")
    try await onResponse(response)
    let bytes = uniform ? Data(repeating: 7, count: Int(expectedRange.length)) : Data((expectedRange.start...expectedRange.endInclusive).map { UInt8($0 % 251) })
    if let earlyOutput, expectedRange.start == 0, bytes.count > 65_536 {
      try await onChunk(Data(bytes.prefix(65_536)))
      consumerSawPrefixBeforeEnd = await earlyOutput.bytes.count == 65_536
      try await onChunk(Data(bytes.dropFirst(65_536)))
    } else { try await onChunk(bytes) }
    return HTTPRangeStreamResult(byteCount: UInt64(bytes.count))
  }
}
private actor StreamOutput {
  var bytes = Data()
  var responses: [HTTPRangeStreamResponse] = []
  func append(_ bytes: Data) { self.bytes.append(bytes) }
  func header(_ response: HTTPRangeStreamResponse) { responses.append(response) }
}
private actor RecoverableRangeFixture: HTTPRangeStreaming {
  var calls: [HTTPByteRange] = []
  var sentPartial = false
  var rejectedSecond = false
  let failure: String
  init(failure: String = "fixtureDisconnect") { self.failure = failure }
  func stream(from url: URL, rangeHeader: String, expectedRange r: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool,
    onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> HTTPRangeStreamResult {
    calls.append(r)
    if r.start == 1_048_576 && !rejectedSecond {
      rejectedSecond = true
      throw HTTPRangeResponseError.statusCode(503)
    }
    try await onResponse(HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: r.start,
      endInclusive: r.endInclusive, completeLength: expectedCompleteLength),
      contentLength: r.length, contentType: "video/mp4"))
    if r.start == 0 && !sentPartial {
      sentPartial = true
      try await onChunk(Data((0..<32_768).map { UInt8($0 % 251) }))
      throw HTTPRangeResponseError.transport(errorType: failure)
    }
    try await onChunk(Data((r.start...r.endInclusive).map { UInt8($0 % 251) }))
    return HTTPRangeStreamResult(byteCount: r.length)
  }
}
@Suite struct ParallelVideoStreamTests {
  @Test func coldFourKSegmentsShareFourLanesInsteadOfOpeningTwentyFourConnections() async throws {
    let source = RangeFixture(delay: .milliseconds(20), uniform: true)
    let stream = ParallelVideoStream(connections: 24, source: source, startup: true)
    let first = StreamOutput(), second = StreamOutput()
    let length: Int64 = 3 * 1024 * 1024
    async let a = read(stream, first, length: length)
    async let b = read(stream, second, length: length)
    _ = try await (a, b)
    #expect(await source.peak == 4)
    #expect(await source.active == 0)
    #expect(await first.bytes == Data(repeating: 7, count: Int(length)))
    #expect(await second.bytes == Data(repeating: 7, count: Int(length)))
    #expect(await source.ranges.count == 8)
    #expect(await stream.statistics()["configuredConnections"] == 24)
    #expect(await stream.statistics()["effectiveConnections"] == 4)
  }
  @Test func startupCeilingIsReleasedGraduallyAndStillRespectsFailures() async throws {
    let permits = VideoStreamPermits(limit: 24, recoveryInterval: .zero, startup: true)
    for _ in 0..<32 { try await permits.acquire(); await permits.release(succeeded: true) }
    #expect(await permits.currentLimit == 4)
    await permits.finishStartup()
    for _ in 0..<4 { try await permits.acquire(); await permits.release(succeeded: true) }
    #expect(await permits.currentLimit == 8)
    await permits.backOff()
    #expect(await permits.currentLimit == 4)
    for _ in 0..<28 { try await permits.acquire(); await permits.release(succeeded: true) }
    #expect(await permits.currentLimit == 24)
    let small = VideoStreamPermits(limit: 2, recoveryInterval: .zero, startup: true)
    await small.finishStartup()
    for _ in 0..<8 { try await small.acquire(); await small.release(succeeded: true) }
    #expect(await small.currentLimit == 2)
  }
  @Test func interruptedBlocksResumeWithoutRepeatingDeliveredBytesOrCompletedSiblings() async throws {
    let output = StreamOutput()
    let fixture = RecoverableRangeFixture()
    let stream = ParallelVideoStream(connections: 4, source: fixture)
    let length: Int64 = 3 * 1024 * 1024 + 7
    _ = try await read(stream, output, length: length)
    #expect(await output.responses.count == 1)
    #expect(await output.bytes == Data((0..<length).map { UInt8($0 % 251) }))
    let calls = await fixture.calls
    #expect(calls.filter { $0.start == 0 }.count == 1)
    #expect(calls.contains { $0.start == 32_768 && $0.endInclusive == 1_048_575 })
    #expect(calls.filter { $0.start == 1_048_576 }.count == 2)
    #expect(calls.filter { $0.start == 2_097_152 }.count == 1)
    let stats = await stream.statistics()
    #expect(stats["retriedBlocks"] == 2)
    #expect(stats["effectiveConnections"] == 2)
  }
  @Test func backoffDoesNotClampTwentyFourToFourAndRecovers() async throws {
    let permits = VideoStreamPermits(limit: 24, recoveryInterval: .zero)
    await permits.backOff()
    #expect(await permits.statistics()["effectiveConnections"] == 12)
    for _ in 0..<12 { try await permits.acquire(); await permits.release(succeeded: true) }
    #expect(await permits.statistics()["effectiveConnections"] == 24)
    #expect(await permits.statistics()["activeVideoRequests"] == 0)
  }
  @Test func firstBytesReachThePlayerBeforeTheFirstBlockFinishes() async throws {
    let output = StreamOutput()
    let fixture = RangeFixture(uniform: true, earlyOutput: output)
    let stream = ParallelVideoStream(connections: 4, source: fixture)
    let length: Int64 = 3 * 1024 * 1024 + 7
    _ = try await read(stream, output, length: length)
    #expect(await fixture.consumerSawPrefixBeforeEnd)
    #expect(await output.responses.count == 1)
    #expect(await output.bytes == Data(repeating: 7, count: Int(length)))
  }
  @Test func thirtyTwoConnectionsAreUsableAndHigherSettingsAreClamped() async throws {
    let fixture = RangeFixture(delay: .milliseconds(40), uniform: true)
    let stream = ParallelVideoStream(connections: 64, source: fixture)
    let output = StreamOutput()
    let length: Int64 = 33 * 1024 * 1024 + 1
    let result = try await read(stream, output, length: length)
    #expect(stream.connections == 32)
    #expect(await fixture.peak == 32)
    #expect(await fixture.active == 0)
    #expect(result.byteCount == UInt64(length))
    #expect(await output.bytes.count == Int(length))
  }
  private func read(
    _ stream: ParallelVideoStream, _ output: StreamOutput, length: Int64 = 5 * 1024 * 1024 + 37
  ) async throws -> HTTPRangeStreamResult {
    try await stream.stream(
      from: URL(string: "https://example.invalid/video.mp4")!,
      rangeHeader: "bytes=0-", expectedRange: HTTPByteRange(start: 0, endInclusive: length - 1),
      expectedCompleteLength: length, headers: [:], allowedContentTypes: ["video/mp4"],
      requiresContentLength: true, onResponse: { await output.header($0) },
      onChunk: { await output.append($0) })
  }
  @Test func outOfOrderBlocksRemainOrderedAndBounded() async throws {
    let source = RangeFixture()
    let stream = ParallelVideoStream(connections: 3, source: source)
    let output = StreamOutput()
    let length: Int64 = 5 * 1024 * 1024 + 37
    let result = try await read(stream, output, length: length)
    let data = await output.bytes
    #expect(data == Data((0..<length).map { UInt8($0 % 251) }))
    #expect(result.byteCount == UInt64(length))
    let peak = await source.peak
    #expect(peak > 1 && peak <= 3)
    let ranges = await source.ranges.sorted { $0.start < $1.start }
    #expect(ranges.count == 6)
    #expect(ranges.allSatisfy { $0.length <= 1024 * 1024 })
    let responses = await output.responses
    #expect(responses.count == 1)
    #expect(responses[0].contentLength == UInt64(length))
    #expect(responses[0].contentRange.endInclusive == length - 1)
  }
  @Test func shortStartupSegmentUsesConfiguredLanesWithoutWaitingForPrefetch() async throws {
    let source = RangeFixture(delay: .milliseconds(40), uniform: true)
    let stream = ParallelVideoStream(connections: 24, source: source)
    let output = StreamOutput()
    let length: Int64 = 3 * 1024 * 1024
    _ = try await read(stream, output, length: length)
    #expect(await source.peak == 24)
    #expect(await output.bytes == Data(repeating: 7, count: Int(length)))
    #expect(await output.responses.count == 1)
    #expect(await source.active == 0)
  }
  @Test func oneConnectionKeepsTheStreamingPath() async throws {
    let source = RangeFixture()
    let stream = ParallelVideoStream(connections: 1, source: source)
    let output = StreamOutput()
    _ = try await read(stream, output)
    #expect(await source.ranges.count == 1)
    #expect(await source.peak == 1)
  }
  @Test func cancellationStopsEveryPendingBlock() async throws {
    let source = RangeFixture(delay: .seconds(30))
    let stream = ParallelVideoStream(connections: 4, source: source)
    let output = StreamOutput()
    let job = Task { try await read(stream, output) }
    try await Task.sleep(for: .milliseconds(30))
    job.cancel()
    await #expect(throws: CancellationError.self) { _ = try await job.value }
    #expect(await source.active == 0)
    #expect(await output.bytes.isEmpty)
  }
  @Test func simultaneousRequestsShareTheLimit() async throws {
    let source = RangeFixture()
    let stream = ParallelVideoStream(connections: 2, source: source)
    async let a = read(stream, StreamOutput(), length: 2 * 1024 * 1024)
    async let b = read(stream, StreamOutput(), length: 2 * 1024 * 1024)
    _ = try await (a, b)
    #expect(await source.peak <= 2)
    #expect(await source.active == 0)
  }
}
