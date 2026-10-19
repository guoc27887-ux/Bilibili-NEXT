import Foundation
import ImageIO

actor ThumbnailCache {
  static let shared = ThumbnailCache()
  private var memory: [URL: Data] = [:]
  private var order: [URL] = []
  private var memoryBytes = 0
  private let cache: URLCache
  private let session: URLSession
  private let decoded = NSCache<NSURL, CGImage>()
  private var inFlight: [URL: Task<CGImage, Error>] = [:]
  private var generation = UUID()
  init() {
    cache = URLCache(
      memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024,
      diskPath: "local.BiliGlass.thumbnails")
    let c = URLSessionConfiguration.default
    c.urlCache = cache
    c.httpCookieStorage = nil
    c.timeoutIntervalForRequest = 20
    session = URLSession(configuration: c)
    decoded.totalCostLimit = 64 * 1024 * 1024
    decoded.countLimit = 120
  }
  func data(_ url: URL) async throws -> Data {
    guard url.scheme == "https", let host = url.host,
      host == "hdslb.com" || host.hasSuffix(".hdslb.com") || host == "biliimg.com"
        || host.hasSuffix(".biliimg.com")
    else { throw BiliError(text: "封面地址无效") }
    if let data = memory[url] { return data }
    var request = URLRequest(url: url)
    API.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      response.mimeType?.hasPrefix("image/") == true, data.count < 64 * 1024 * 1024
    else { throw BiliError(text: "封面不可用") }
    if memory[url] == nil && data.count <= 32 * 1024 * 1024 {
      while memoryBytes + data.count > 32 * 1024 * 1024, let oldest = order.first {
        order.removeFirst()
        memoryBytes -= memory.removeValue(forKey: oldest)?.count ?? 0
      }
      memory[url] = data
      order.append(url)
      memoryBytes += data.count
    }
    return data
  }
  func thumbnail(_ url: URL) async throws -> CGImage {
    if let image = decoded.object(forKey: url as NSURL) { return image }
    if let pending = inFlight[url] { return try await pending.value }
    let token = generation
    let pending = Task {
      let data = try await self.data(url)
      try Task.checkCancellation()
      return try await Self.decode(data)
    }
    inFlight[url] = pending
    defer { if token == generation { inFlight[url] = nil } }
    let image = try await pending.value
    try Task.checkCancellation()
    if token == generation { decoded.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height) }
    return image
  }
  private static func decode(_ data: Data) async throws -> CGImage {
    try await Task.detached(priority: .utility) {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      else { throw BiliError(text: "图片无法解码") }
      return image
    }.value
  }
  func clear() {
    generation = UUID()
    inFlight.values.forEach { $0.cancel() }; inFlight.removeAll()
    decoded.removeAllObjects()
    memory.removeAll()
    order.removeAll()
    memoryBytes = 0
    cache.removeAllCachedResponses()
  }
}
