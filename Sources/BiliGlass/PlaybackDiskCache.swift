import BiliNetworking
import Foundation
import Darwin

/// Session-only media pages. Signed URLs stay in memory, never in filenames or manifests.
/// The HLS timeline remains authoritative; prefetch completion never changes AVPlayer state.
actor PlaybackDiskCache: HTTPRangeStreaming {
  static let pageSize: Int64 = 1_048_576
  private struct Page: Sendable { let file: URL; let response: HTTPRangeStreamResponse }
  private struct Track {
    let id: UUID, length: Int64, headers: [String: String], types: Set<String>?
    var cursor: Int64
    var pages: [Int64: Page] = [:]
    var running: [Int64: Task<Page, Error>] = [:]
  }
  private let source: any HTTPRangeStreaming
  private let videoURLs: Set<URL>
  private let permits: VideoStreamPermits
  private let prefetchConnections: Int
  private let capacity: Int64
  let directory: URL
  private let lease: Int32
  private var tracks: [URL: Track] = [:]
  private var workers: [URL: Task<Void, Never>] = [:]
  private var startupRequests: [UUID: Task<HTTPRangeStreamResult, Error>] = [:]
  private let streamDuringStartup: Bool
  private var started = false
  private var stopped = false
  private var storageLimited = false
  private var stored: Int64 = 0
  private var hits = 0
  private var lastSpaceCheck: Int64 = -64 * 1_048_576
  private let reserveSpace: Int64

  init(source: any HTTPRangeStreaming, videoURLs: Set<URL>, connections: Int,
       capacity: Int64 = 8 * 1_073_741_824, reserveSpace: Int64 = 1_073_741_824,
       streamDuringStartup: Bool = false,
       root: URL = PlaybackTemporaryFiles.root) throws {
    self.source = source; self.videoURLs = videoURLs
    self.streamDuringStartup = streamDuringStartup
    permits = VideoStreamPermits(limit: max(1, min(32, connections)), startup: streamDuringStartup)
    self.capacity = capacity; self.reserveSpace = reserveSpace
    prefetchConnections = max(1, min(32, connections))
    directory = root.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = Darwin.open(directory.appendingPathComponent(".lease").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if descriptor >= 0 { Darwin.close(descriptor) }
      try? FileManager.default.removeItem(at: directory)
      throw CocoaError(.fileWriteUnknown)
    }
    lease = descriptor
  }
  deinit { Darwin.close(lease) }

  func start() async {
    guard !stopped else { return }; started = true
    await permits.finishStartup()
    guard !stopped else { return }
    for url in tracks.keys { startWorker(url) }
  }
  func stop() async {
    guard !stopped else { return }; stopped = true
    let tasks = tracks.values.flatMap { $0.running.values }
    let startup = Array(startupRequests.values)
    workers.values.forEach { $0.cancel() }; workers = [:]
    tasks.forEach { $0.cancel() }
    startup.forEach { $0.cancel() }
    for task in tasks { _ = try? await task.value }
    for task in startup { _ = try? await task.value }
    startupRequests = [:]
    tracks = [:]
    try? FileManager.default.removeItem(at: directory)
  }
  func statistics() async -> [String: Int] {
    var result = await permits.statistics()
    result["diskCacheBytes"] = Int(stored)
    result["diskCacheTotal"] = Int(tracks.values.reduce(0) { $0 + $1.length })
    result["diskCacheHits"] = hits
    result["diskCacheLimited"] = storageLimited ? 1 : 0
    result["diskCacheComplete"] = !tracks.isEmpty && tracks.values.allSatisfy { Int64($0.pages.count) == ($0.length + Self.pageSize - 1) / Self.pageSize } ? 1 : 0
    return result
  }
  func stream(from url: URL, rangeHeader: String, expectedRange: HTTPByteRange,
              expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
              requiresContentLength: Bool,
              onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
              onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> HTTPRangeStreamResult {
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    // Metadata probes have no validated total length yet and keep their small direct path.
    guard let length = expectedCompleteLength, length > 0, expectedRange.endInclusive < length,
          rangeHeader == expectedRange.headerValue else {
      return try await source.stream(from: url, rangeHeader: rangeHeader, expectedRange: expectedRange,
        expectedCompleteLength: expectedCompleteLength, headers: headers, allowedContentTypes: allowedContentTypes,
        requiresContentLength: requiresContentLength, onResponse: onResponse, onChunk: onChunk)
    }
    defer { if started { startWorker(url) } }
    let first = expectedRange.start / Self.pageSize, last = expectedRange.endInclusive / Self.pageSize
    if let track = tracks[url] {
      guard track.length == length else { throw HTTPRangeResponseError.rejectedBody }
    } else {
      tracks[url] = Track(id: UUID(), length: length, headers: headers, types: allowedContentTypes, cursor: first)
    }
    if streamDuringStartup && !started {
      // Init boxes and short audio/video segments must reach AVPlayer immediately.
      // Expanding an init read to a whole 1 MiB page delays every quality switch,
      // and withholding chunks until the page completes can stall startup entirely.
      // Remember the resume segment so later read-ahead starts around the playhead.
      if expectedRange.start > 0 { tracks[url]?.cursor = first }
      let id = UUID()
      let request = Task { [source] in
        try await source.stream(from: url, rangeHeader: rangeHeader, expectedRange: expectedRange,
          expectedCompleteLength: length, headers: headers, allowedContentTypes: allowedContentTypes,
          requiresContentLength: requiresContentLength, onResponse: onResponse, onChunk: onChunk)
      }
      startupRequests[id] = request
      defer { startupRequests[id] = nil }
      return try await withTaskCancellationHandler {
        let result = try await request.value
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        return result
      } onCancel: { request.cancel() }
    }
    for number in first...last {
      let lower = max(expectedRange.start, number * Self.pageSize)
      let upper = min(expectedRange.endInclusive, (number + 1) * Self.pageSize - 1)
      let slice = try HTTPByteRange(start: lower, endInclusive: upper)
      func direct() async throws {
        _ = try await source.stream(from: url, rangeHeader: slice.headerValue, expectedRange: slice,
          expectedCompleteLength: length, headers: headers, allowedContentTypes: allowedContentTypes,
          requiresContentLength: requiresContentLength, onResponse: { response in
            if number == first {
              try await onResponse(HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: expectedRange.start,
                endInclusive: expectedRange.endInclusive, completeLength: length), contentLength: expectedRange.length,
                contentType: response.contentType))
            }
          }, onChunk: onChunk)
      }
      if tracks[url]?.pages[number] == nil && tracks[url]?.running[number] == nil {
        if !hasSpace(for: min(Self.pageSize, length - number * Self.pageSize)) { storageLimited = true }
        if storageLimited { try await direct(); continue }
      }
      let page: Page
      do { page = try await self.page(url, number: number, foreground: true) }
      catch let failure as CocoaError where [.fileWriteOutOfSpace, .fileWriteNoPermission, .fileWriteUnknown].contains(failure.code) {
        storageLimited = true
        try await direct(); continue
      }
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      if let allowedContentTypes, !allowedContentTypes.contains(page.response.contentType ?? "") { throw HTTPRangeResponseError.rejectedBody }
      if number == first {
        try await onResponse(HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: expectedRange.start,
          endInclusive: expectedRange.endInclusive, completeLength: length), contentLength: expectedRange.length,
          contentType: page.response.contentType))
      }
      let handle = try FileHandle(forReadingFrom: page.file)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(lower - number * Self.pageSize))
      var remaining = Int(upper - lower + 1)
      while remaining > 0 {
        try Task.checkCancellation()
        guard let bytes = try handle.read(upToCount: min(65_536, remaining)), !bytes.isEmpty else { throw HTTPRangeResponseError.rejectedBody }
        try await onChunk(bytes); remaining -= bytes.count
      }
    }
    return HTTPRangeStreamResult(byteCount: expectedRange.length)
  }
  private func page(_ url: URL, number: Int64, foreground: Bool) async throws -> Page {
    guard !stopped, let track = tracks[url] else { throw CancellationError() }
    if let cached = track.pages[number] { hits += foreground ? 1 : 0; return cached }
    if let running = track.running[number] { return try await running.value }
    let range = try HTTPByteRange(start: number * Self.pageSize, endInclusive: min(track.length - 1, (number + 1) * Self.pageSize - 1))
    if !foreground && !hasSpace(for: Int64(range.length)) { storageLimited = true; throw CocoaError(.fileWriteOutOfSpace) }
    let file = directory.appendingPathComponent("\(track.id)-\(number).page")
    let video = videoURLs.contains(url) || track.types?.contains("video/mp4") == true
    let task = Task<Page, Error> { [source, permits] in
      if video { try await permits.acquire(foreground: foreground) }
      do {
        let buffer = try DiskPageWriter(file: file)
        defer { buffer.close() }
        var retries = 0
        while buffer.byteCount < range.length {
          let remaining = try HTTPByteRange(start: range.start + Int64(buffer.byteCount), endInclusive: range.endInclusive)
          do {
            _ = try await source.stream(from: url, rangeHeader: remaining.headerValue, expectedRange: remaining,
              expectedCompleteLength: track.length, headers: track.headers, allowedContentTypes: track.types,
              requiresContentLength: true, onResponse: { try buffer.header($0) },
              onChunk: { try buffer.append($0) })
            guard buffer.byteCount == range.length else { throw HTTPRangeResponseError.rejectedBody }
          } catch {
            try Task.checkCancellation()
            guard retries < 3, ParallelVideoStream.canResume(error) else { throw error }
            retries += 1
            if video { await permits.backOff() }
            try await Task.sleep(for: .milliseconds(150 * retries))
          }
        }
        try Task.checkCancellation()
        let response = try buffer.complete(length: range.length)
        if video { await permits.release(succeeded: true) }
        return Page(file: file, response: response)
      } catch {
        if video { await permits.release() }; throw error
      }
    }
    tracks[url]?.running[number] = task
    do {
      let value = try await task.value
      tracks[url]?.running[number] = nil
      guard !stopped else { throw CancellationError() }
      tracks[url]?.pages[number] = value
      stored += Int64(range.length)
      return value
    } catch { tracks[url]?.running[number] = nil; throw error }
  }
  private func hasSpace(for bytes: Int64) -> Bool {
    let reserved = tracks.values.reduce(Int64(0)) { $0 + Int64($1.running.count) * Self.pageSize }
    guard stored + reserved + bytes <= capacity else { return false }
    if stored - lastSpaceCheck >= 64 * Self.pageSize {
      lastSpaceCheck = stored
      let free = (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
      if free < reserveSpace + 64 * Self.pageSize { return false }
    }
    return true
  }
  private func startWorker(_ url: URL) {
    guard started, !stopped, !storageLimited, workers[url] == nil else { return }
    let lanes = videoURLs.contains(url) ? prefetchConnections : 1
    workers[url] = Task(priority: .utility) { [weak self] in
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<lanes { group.addTask { await self?.prefetch(url) } }
      }
      await self?.finishedWorker(url)
    }
  }
  private func prefetch(_ url: URL) async {
    var failures = 0
    while !Task.isCancelled {
      guard !stopped, let track = tracks[url] else { break }
      let pageCount = (track.length + Self.pageSize - 1) / Self.pageSize
      var next = track.cursor % pageCount
      var scanned: Int64 = 0
      while track.pages[next] != nil || track.running[next] != nil {
        next = (next + 1) % pageCount
        scanned += 1
        if scanned == pageCount { break }
      }
      guard scanned < pageCount else { break }
      tracks[url]?.cursor = next + 1
      guard next * Self.pageSize < track.length, !storageLimited else { break }
      do { _ = try await page(url, number: next, foreground: false); failures = 0 }
      catch {
        if Task.isCancelled || stopped || storageLimited { break }
        tracks[url]?.cursor = min(tracks[url]?.cursor ?? next, next)
        failures += 1
        try? await Task.sleep(for: .seconds(min(10, failures)))
      }
    }
  }
  private func finishedWorker(_ url: URL) { workers[url] = nil }

}
/// Stream each validated prefix to a private partial file. The completed page is
/// published only after length validation. No 1 MiB Data buffer per connection.
final class DiskPageWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let file: URL
  private let partial: URL
  private let handle: FileHandle
  private var response: HTTPRangeStreamResponse?
  private var received: UInt64 = 0
  private var closed = false
  var byteCount: UInt64 { lock.withLock { received } }
  init(file: URL) throws {
    self.file = file
    partial = file.appendingPathExtension("partial")
    guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    handle = try FileHandle(forWritingTo: partial)
  }
  func header(_ response: HTTPRangeStreamResponse) throws { try lock.withLock {
    if let previous = self.response {
      guard previous.contentRange.completeLength == response.contentRange.completeLength,
        previous.contentType == response.contentType else { throw HTTPRangeResponseError.rejectedBody }
    } else { self.response = response }
  } }
  func append(_ bytes: Data) throws { try lock.withLock {
    guard !closed, received + UInt64(bytes.count) <= PlaybackDiskCache.pageSize else { throw HTTPRangeResponseError.rejectedBody }
    try handle.write(contentsOf: bytes)
    received += UInt64(bytes.count)
  } }
  func complete(length: UInt64) throws -> HTTPRangeStreamResponse { try lock.withLock {
    guard !closed, let response, received == length else { throw HTTPRangeResponseError.rejectedBody }
    try handle.close(); closed = true
    try FileManager.default.moveItem(at: partial, to: file)
    return response
  } }
  func close() { lock.withLock {
    if !closed { try? handle.close(); closed = true }
    try? FileManager.default.removeItem(at: partial)
  } }
  deinit { close() }
}
enum PlaybackTemporaryFiles {
  static var root: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BiliGlass/Playback", isDirectory: true) }
  static func cleanup(staleOnly: Bool = true, root: URL = root) {
    for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
      guard folder.lastPathComponent.contains("-") else { continue }
      let fd = Darwin.open(folder.appendingPathComponent(".lease").path, O_RDWR)
      defer { if fd >= 0 { Darwin.close(fd) } }
      let owned = folder.lastPathComponent.hasPrefix("\(getpid())-")
      if (!staleOnly && owned) || (fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0) { try? FileManager.default.removeItem(at: folder) }
    }
  }
}
