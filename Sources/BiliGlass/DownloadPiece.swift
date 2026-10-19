import BiliNetworking
import Foundation

/// Keeps a verified contiguous prefix on disk, including when the job is paused.
/// A disconnect retries only the missing tail; CDNTransport repairs bad nodes.
enum DownloadPiece {
  static func fetch(_ url: URL, range: HTTPByteRange, total: Int64, target: URL,
    transport: any HTTPRangeStreaming, update: @escaping @Sendable (Double) -> Void) async throws {
    let partial = target.appendingPathExtension("partial")
    let writer = try PieceWriter(partial, limit: range.length)
    do {
      var failures = 0
      while await writer.count < range.length {
        try Task.checkCancellation()
        let offset = await writer.count
        let start = range.start + Int64(offset)
        let request = try HTTPByteRange(start: start, endInclusive: min(range.endInclusive, start + 1_048_575))
        do {
          _ = try await transport.stream(from: url, rangeHeader: request.headerValue,
            expectedRange: request, expectedCompleteLength: total, headers: API.mediaHeaders,
            allowedContentTypes: ["video/mp4", "audio/mp4", "application/octet-stream"], requiresContentLength: true,
            onResponse: { _ in }, onChunk: { data in
              try await writer.append(data)
              update(Double(await writer.count) / Double(range.length))
            })
          guard await writer.count > offset else { throw HTTPRangeResponseError.rejectedBody }
          failures = 0
        } catch {
          try Task.checkCancellation()
          guard failures < 3, await !writer.failed, retryable(error) else { throw error }
          failures += 1
          try await Task.sleep(for: .milliseconds(200 * failures))
        }
      }
      try await writer.close()
      try Task.checkCancellation()
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.moveItem(at: partial, to: target)
      update(1)
    } catch {
      try? await writer.close()
      throw error
    }
  }
  private static func retryable(_ error: Error) -> Bool {
    if error is CDNIdleTimeout { return true }
    if let error = error as? HTTPRangeResponseError {
      switch error {
      case .transport, .bodyLengthMismatch: return true
      case .statusCode(let code): return [408, 429, 500, 502, 503, 504].contains(code)
      default: return false
      }
    }
    return false
  }
}
private actor PieceWriter {
  private let file: FileHandle
  private let limit: UInt64
  private var closed = false
  var count: UInt64
  var failed = false
  init(_ path: URL, limit: UInt64) throws {
    self.limit = limit
    let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.uint64Value ?? 0
    if size > limit { try FileManager.default.removeItem(at: path) }
    if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
    file = try FileHandle(forWritingTo: path)
    count = try file.seekToEnd()
  }
  func append(_ data: Data) throws {
    do {
      try Task.checkCancellation()
      guard !closed, count + UInt64(data.count) <= limit else { throw HTTPRangeResponseError.rejectedBody }
      try file.write(contentsOf: data)
      count += UInt64(data.count)
    } catch { failed = true; throw error }
  }
  func close() throws {
    guard !closed else { return }
    closed = true
    defer { try? file.close() }
    try file.synchronize()
  }
  deinit { try? file.close() }
}

func downloadIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
  let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try operation() }
  return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
