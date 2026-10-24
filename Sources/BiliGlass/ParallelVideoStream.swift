import BiliNetworking
import Foundation

/// Bounded parallel reads behind the local player URL. Only video media requests use it;
/// metadata and audio keep the normal streaming path. Completed blocks are emitted in order.
final class ParallelVideoStream: HTTPRangeStreaming, Sendable {
  let connections: Int
  private let videoURLs: Set<URL>
  private let source: any HTTPRangeStreaming
  private let permits: VideoStreamPermits
  static let blockSize: Int64 = 1024 * 1024

  init(
    connections: Int, videoURLs: Set<URL> = [],
    source: any HTTPRangeStreaming = HTTPRangeStreamingClient(), startup: Bool = false
  ) {
    self.videoURLs = videoURLs
    self.connections = max(1, min(32, connections))
    self.source = source
    permits = VideoStreamPermits(limit: self.connections, startup: startup)
  }

  func statistics() async -> [String: Int] { await permits.statistics() }
  func finishStartup() async { await permits.finishStartup() }

  func stream(
    from url: URL, rangeHeader: String, expectedRange: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool,
    onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> HTTPRangeStreamResult {
    let isVideo =
      videoURLs.contains(url)
      || allowedContentTypes?.contains(where: { $0.lowercased().hasPrefix("video/") }) == true
    // A 4K segment split across 24–32 cold requests can spend seconds opening
    // connections and waiting for its slowest piece. Start with at most four
    // lanes, then grow after playback has usable media. Use the same lane count
    // for partitioning and admission so queued tiny pieces cannot delay the head.
    let lanes = await permits.currentLimit
    let blockSize = Self.blockSize(length: expectedRange.length, connections: lanes)
    guard connections > 1, isVideo, expectedRange.length > UInt64(blockSize) else {
      return try await source.stream(
        from: url, rangeHeader: rangeHeader, expectedRange: expectedRange,
        expectedCompleteLength: expectedCompleteLength, headers: headers,
        allowedContentTypes: allowedContentTypes, requiresContentLength: requiresContentLength,
        onResponse: onResponse, onChunk: onChunk)
    }
    guard rangeHeader.lowercased().hasPrefix("bytes="), !rangeHeader.contains(",") else {
      throw HTTPRangeResponseError.invalidRangeHeader
    }
    return try await withThrowingTaskGroup(of: VideoStreamBlock.self) { group in
      var scheduled = 0
      var nextStart = expectedRange.start
      var hasRemaining = true
      func schedule() throws {
        guard hasRemaining else { return }
        let start = nextStart
        let end = start + min(blockSize - 1, expectedRange.endInclusive - start)
        let range = try HTTPByteRange(start: start, endInclusive: end)
        let index = scheduled
        scheduled += 1
        if end == expectedRange.endInclusive { hasRemaining = false } else { nextStart = end + 1 }
        group.addTask { [source, permits] in
          try await permits.acquire()
          do {
            try Task.checkCancellation()
            let buffer = VideoStreamBuffer()
            var retries = 0
            while await buffer.byteCount < range.length {
              let remaining = try await HTTPByteRange(
                start: range.start + Int64(buffer.byteCount), endInclusive: range.endInclusive)
              do {
                _ = try await source.stream(
                  from: url, rangeHeader: remaining.headerValue, expectedRange: remaining,
                  expectedCompleteLength: expectedCompleteLength, headers: headers,
                  allowedContentTypes: allowedContentTypes, requiresContentLength: requiresContentLength,
                  onResponse: { response in
                    let firstResponse = try await buffer.setResponse(response, original: range)
                    if index == 0 && firstResponse {
                      do {
                        try await onResponse(HTTPRangeStreamResponse(
                          contentRange: HTTPContentRange(start: expectedRange.start,
                            endInclusive: expectedRange.endInclusive,
                            completeLength: response.contentRange.completeLength),
                          contentLength: expectedRange.length, contentType: response.contentType))
                      } catch { await buffer.consumerFailed(); throw error }
                    }
                  },
                  onChunk: { bytes in
                    if index == 0 {
                      do { try await onChunk(bytes) }
                      catch { await buffer.consumerFailed(); throw error }
                    }
                    try await buffer.append(bytes, streamed: index == 0)
                  })
                guard await buffer.byteCount == range.length else {
                  throw HTTPRangeResponseError.rejectedBody
                }
              } catch {
                try Task.checkCancellation()
                guard retries < 3, Self.canResume(error), await !buffer.downstreamFailed else { throw error }
                retries += 1
                await permits.backOff()
                // Keep completed siblings and the validated contiguous prefix. Only
                // request the missing suffix from this exact, pinned media resource.
                try await Task.sleep(for: .milliseconds(250 * retries))
              }
            }
            let block = try await buffer.block(index: index, streamed: index == 0)
            await permits.release(succeeded: true)
            return block
          } catch {
            await permits.release()
            throw error
          }
        }
      }
      defer { group.cancelAll() }
      for _ in 0..<lanes { try schedule() }
      var pending: [Int: VideoStreamBlock] = [:]
      var emitting = 0
      var emitted: UInt64 = 0
      var completeLength = expectedCompleteLength
      while let block = try await group.next() {
        pending[block.index] = block
        while let ready = pending.removeValue(forKey: emitting) {
          try Task.checkCancellation()
          if let completeLength, let actual = ready.response.contentRange.completeLength,
            actual != completeLength
          {
            throw HTTPRangeResponseError.mismatchedCompleteLength(
              expected: completeLength, actual: actual)
          }
          if emitted == 0 { completeLength = ready.response.contentRange.completeLength }
          if ready.streamed == nil { try await onChunk(ready.data) }
          emitted += ready.streamed ?? UInt64(ready.data.count)
          emitting += 1
          // A new block is admitted only after the player consumed an ordered block.
          // Thus pending data stays below connections * 1 MiB, even for an open-ended request.
          try schedule()
        }
      }
      guard emitted == expectedRange.length else {
        throw HTTPRangeResponseError.bodyLengthMismatch(
          expected: expectedRange.length, actual: emitted)
      }
      return HTTPRangeStreamResult(byteCount: emitted)
    }
  }
  static func blockSize(length: UInt64, connections: Int) -> Int64 {
    let lanes = max(1, min(32, connections))
    // A short HLS segment often contains only 1–3 MiB. Fixed 1 MiB blocks
    // leave most configured lanes idle until full-file prefetch starts.
    if (length + UInt64(blockSize) - 1) / UInt64(blockSize) >= lanes { return blockSize }
    let quantum: UInt64 = 65_536
    return Int64(max(quantum, min(UInt64(blockSize), (length / UInt64(lanes) / quantum) * quantum)))
  }
  static func canResume(_ error: Error) -> Bool {
    if error is CDNIdleTimeout { return true }
    if let error = error as? URLError { return [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) }
    guard let error = error as? HTTPRangeResponseError else { return false }
    switch error {
    case .statusCode(let code): return [408, 429, 500, 502, 503, 504].contains(code)
    case .transport, .bodyLengthMismatch: return true
    default: return false
    }
  }
}

private struct VideoStreamBlock: Sendable {
  let index: Int
  let response: HTTPRangeStreamResponse
  let data: Data
  let streamed: UInt64?
}
private actor VideoStreamBuffer {
  var response: HTTPRangeStreamResponse?
  var data = Data()
  var byteCount: UInt64 = 0
  var downstreamFailed = false
  func consumerFailed() { downstreamFailed = true }
  func setResponse(_ value: HTTPRangeStreamResponse, original: HTTPByteRange) throws -> Bool {
    if let response {
      guard response.contentRange.completeLength == value.contentRange.completeLength,
        response.contentType == value.contentType else { throw HTTPRangeResponseError.rejectedBody }
      return false
    }
    response = try HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: original.start,
      endInclusive: original.endInclusive, completeLength: value.contentRange.completeLength),
      contentLength: original.length, contentType: value.contentType)
    return true
  }
  func append(_ bytes: Data, streamed: Bool) throws {
    guard byteCount + UInt64(bytes.count) <= UInt64(ParallelVideoStream.blockSize) else {
      throw HTTPRangeResponseError.bodyLengthMismatch(
        expected: UInt64(ParallelVideoStream.blockSize), actual: UInt64(data.count + bytes.count))
    }
    byteCount += UInt64(bytes.count)
    if !streamed { data.append(bytes) }
  }
  func block(index: Int, streamed: Bool) throws -> VideoStreamBlock {
    guard let response, byteCount == response.contentLength else {
      throw HTTPRangeResponseError.rejectedBody
    }
    return VideoStreamBlock(index: index, response: response, data: data, streamed: streamed ? byteCount : nil)
  }
}
actor VideoStreamPermits {
  private var peak = 0
  private var active = 0
  private var blocks = 0
  private var limit: Int
  private let maximum: Int
  private let recoveryInterval: Duration
  private var starting: Bool
  var currentLimit: Int { limit }
  private var successfulBlocks = 0
  private var lastFailure: ContinuousClock.Instant?
  private var retries = 0
  private var lastReduction: ContinuousClock.Instant?
  private var lastRecovery: ContinuousClock.Instant?
  private var waiters: [(UUID, CheckedContinuation<Void, Error>, Bool)] = []
  init(limit: Int, recoveryInterval: Duration = .seconds(2), startup: Bool = false) {
    maximum = max(1, min(32, limit)); self.limit = startup ? min(4, maximum) : maximum
    self.recoveryInterval = recoveryInterval
    starting = startup
  }
  func finishStartup() {
    guard starting else { return }
    starting = false
    successfulBlocks = 0
    lastRecovery = .now
  }
  func acquire(foreground: Bool = true) async throws {
    try Task.checkCancellation()
    if active < limit {
      active += 1
      blocks += 1
      peak = max(peak, active)
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          if foreground { waiters.insert((id, continuation, true), at: waiters.firstIndex(where: { !$0.2 }) ?? waiters.endIndex) }
          else { waiters.append((id, continuation, false)) }
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }
  private func cancel(_ id: UUID) {
    if let index = waiters.firstIndex(where: { $0.0 == id }) {
      waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
  }
  func statistics() -> [String: Int] {
    ["peakVideoRequests": peak, "videoBlocks": blocks, "effectiveConnections": limit, "configuredConnections": maximum, "activeVideoRequests": active, "queuedVideoRequests": waiters.count, "retriedBlocks": retries]
  }
  func backOff() {
    retries += 1; successfulBlocks = 0; lastFailure = .now; lastRecovery = nil
    if lastReduction == nil || lastReduction!.duration(to: .now) >= .seconds(2) {
      limit = max(1, limit / 2); lastReduction = .now
    }
  }
  func release(succeeded: Bool = false) {
    if succeeded {
      successfulBlocks += 1
      let ceiling = starting ? min(4, maximum) : maximum
      if limit < ceiling, successfulBlocks >= limit,
        (lastFailure == nil || lastFailure!.duration(to: .now) >= recoveryInterval),
        (lastRecovery == nil || lastRecovery!.duration(to: .now) >= recoveryInterval) {
        limit = min(ceiling, limit * 2); successfulBlocks = 0; lastRecovery = .now
      }
    }
    active -= 1
    while active < limit && !waiters.isEmpty {
      active += 1
      blocks += 1
      peak = max(peak, active)
      waiters.removeFirst().1.resume()
    }
  }
}
