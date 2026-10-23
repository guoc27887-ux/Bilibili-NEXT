import ImageIO
import SwiftUI

final class PreviewSheet: @unchecked Sendable {
  let image: CGImage
  let sourceWidth: Int
  let sourceHeight: Int
  var width: Int { image.width }
  var height: Int { image.height }
  init(image: CGImage, sourceWidth: Int? = nil, sourceHeight: Int? = nil) {
    self.image = image; self.sourceWidth = sourceWidth ?? image.width; self.sourceHeight = sourceHeight ?? image.height
  }
}

struct VideoPreviewFrame: Hashable, Sendable {
  let url: URL
  let index: Int
  let columns: Int
  let rows: Int
  var cellWidth = 0
  var cellHeight = 0
  func crop(_ sheet: PreviewSheet) throws -> CGImage {
    guard (1...100).contains(columns), (1...100).contains(rows), (0..<(columns * rows)).contains(index) else { throw BiliError(text: "预览索引无效") }
    let width = cellWidth > 0 ? cellWidth : sheet.sourceWidth / columns
    let height = cellHeight > 0 ? cellHeight : sheet.sourceHeight / rows
    guard width > 0, height > 0, width <= sheet.sourceWidth, height <= sheet.sourceHeight else { throw BiliError(text: "预览尺寸无效") }
    let x = (index % columns) * width, y = (index / columns) * height
    guard x <= sheet.sourceWidth - width, y <= sheet.sourceHeight - height else { throw BiliError(text: "预览图片不完整") }
    let sx = Double(sheet.width) / Double(sheet.sourceWidth), sy = Double(sheet.height) / Double(sheet.sourceHeight)
    let rect = CGRect(x: Double(x) * sx, y: Double(y) * sy, width: Double(width) * sx, height: Double(height) * sy).integral
      .intersection(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
    guard let image = sheet.image.cropping(to: rect) else { throw BiliError(text: "预览图片不完整") }
    return image
  }
}

actor PreviewSheets {
  static let shared = PreviewSheets()
  private let cache = NSCache<NSURL, PreviewSheet>()
  private var tasks: [URL: Task<PreviewSheet, Error>] = [:]
  init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 4 }
  func image(_ url: URL) async throws -> PreviewSheet {
    if let image = cache.object(forKey: url as NSURL) { return image }
    if let task = tasks[url] { return try await task.value }
    let task = Task {
      let data = try await ThumbnailCache.shared.data(url)
      return try await Self.decode(data)
    }
    tasks[url] = task; defer { tasks[url] = nil }
    let sheet = try await task.value
    cache.setObject(sheet, forKey: url as NSURL, cost: sheet.image.bytesPerRow * sheet.height)
    return sheet
  }
  nonisolated static func decode(_ data: Data) async throws -> PreviewSheet {
    try await Task.detached(priority: .utility) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, Int64(width) * Int64(height) <= 30_000_000,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary) else { throw BiliError(text: "预览图片无效") }
        // 4800x2700 sheets decode to 52 MB, exceeding the 32 MB cache budget.
        // Bound decoded memory and retain source dimensions for exact tile crops.
        return PreviewSheet(image: image, sourceWidth: width, sourceHeight: height)
    }.value
  }
}

@MainActor @Observable final class VideoPreviewModel {
  private(set) var image: CGImage?
  private(set) var loading = false
  private(set) var unavailable = false
  private var generation = UUID()
  private let loadSheet: @Sendable (URL) async throws -> PreviewSheet
  init(loadSheet: @escaping @Sendable (URL) async throws -> PreviewSheet = { try await PreviewSheets.shared.image($0) }) { self.loadSheet = loadSheet }
  func load(_ frame: VideoPreviewFrame?) async {
    guard !Task.isCancelled else { return }
    generation = UUID(); let token = generation
    image = nil; unavailable = frame == nil; loading = frame != nil
    guard let frame else { return }
    defer { if token == generation { loading = false } }
    do {
      let sheet = try await loadSheet(frame.url)
      guard token == generation, !Task.isCancelled else { return }
      image = try frame.crop(sheet)
    } catch {
      // A cancelled hover may finish after a newer request succeeds. Neither
      // its success nor its failure may change the newer preview.
      guard token == generation, !Task.isCancelled else { return }
      image = nil; unavailable = true
    }
  }
  func cancel() { generation = UUID(); loading = false }
}

struct VideoPreview: View {
  let shots: VideoShots
  let time: Double
  @State private var model = VideoPreviewModel()
  var body: some View {
    let frame = shots.frame(at: time)
    VStack(spacing: 5) {
      if !model.unavailable {
        ZStack {
          if let image = model.image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
          else { Rectangle().fill(.white.opacity(0.08)); ProgressView().controlSize(.small).tint(.white).accessibilityLabel("正在加载预览") }
        }.frame(width: 160, height: 90)
      } else { Text("预览暂不可用").font(.caption2).foregroundStyle(.white.opacity(0.7)) }
      Text(String(format: "%d:%02d", Int(max(0, time)) / 60, Int(max(0, time)) % 60)).font(.caption.monospacedDigit()).foregroundStyle(.white)
    }.frame(width: 160).padding(6).background(.black.opacity(0.9), in: .rect(cornerRadius: 9)).allowsHitTesting(false)
      .task(id: frame) { await model.load(frame) }
      .onDisappear { model.cancel() }
  }
}
