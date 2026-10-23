#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

struct CommentEmote: Hashable, Sendable {
  let token: String
  let url: URL
  let large: Bool

  static func parse(_ raw: Any?) -> [String: CommentEmote] {
    guard let entries = raw as? [String: [String: Any]] else { return [:] }
    var result: [String: CommentEmote] = [:]
    for (token, entry) in entries.sorted(by: { $0.key < $1.key }).prefix(128) {
      guard !token.isEmpty, token.count <= 128, let address = entry["url"] as? String,
        var url = URLComponents(string: address.hasPrefix("//") ? "https:" + address : address),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        let host = url.host?.lowercased(),
        host == "hdslb.com" || host.hasSuffix(".hdslb.com") || host == "biliimg.com" || host.hasSuffix(".biliimg.com"),
        url.user == nil, url.password == nil else { continue }
      url.scheme = "https"
      guard let imageURL = url.url else { continue }
      let size = (entry["meta"] as? [String: Any])?["size"] as? Int ?? 1
      result[token] = CommentEmote(token: token, url: imageURL, large: size == 2)
    }
    return result
  }
  static func privateMessages(_ raw: Any?) -> [String: CommentEmote] {
    let rows = raw as? [[String: Any]] ?? []
    let entries = rows.reduce(into: [String: [String: Any]]()) { result, row in
      guard let token = row["text"] as? String else { return }
      result[token] = ["url": row["url"] ?? "", "meta": ["size": row["size"] ?? 1]]
    }
    return parse(entries)
  }
}

enum CommentTextPart: Hashable, Sendable {
  case text(String)
  case emote(CommentEmote)
}

struct CommentTextContent: Hashable, Sendable {
  let message: String
  let parts: [CommentTextPart]

  init(message: String, emotes: [String: CommentEmote]) {
    self.message = message
    guard !emotes.isEmpty, message.utf16.count <= 64_000 else {
      parts = [.text(message)]; return
    }
    var result: [CommentTextPart] = []
    var start = message.startIndex
    // Tokens are delimited, so adjacent/duplicate emotes and Unicode remain intact.
    while let open = message[start...].firstIndex(of: "["),
      let close = message[open...].firstIndex(of: "]")
    {
      let end = message.index(after: close)
      let token = String(message[open..<end])
      if let emote = emotes[token] {
        if start < open { result.append(.text(String(message[start..<open]))) }
        result.append(.emote(emote))
        start = end
      } else {
        // Keep unknown bracketed text exactly as authored.
        result.append(.text(String(message[start..<end])))
        start = end
      }
    }
    if start < message.endIndex { result.append(.text(String(message[start...]))) }
    parts = result
  }
  var emotes: [CommentEmote] {
    var seen: Set<URL> = []
    return parts.compactMap {
      guard case .emote(let emote) = $0, seen.insert(emote.url).inserted else { return nil }
      return emote
    }
  }
}

/// A single native Text keeps wrapping and selection; no web view or per-frame timer.
struct CommentText: View {
  let content: CommentTextContent
  var copyTitle = "复制评论"
  @State private var images: [URL: CGImage] = [:]
  @ScaledMetric(relativeTo: .body) private var smallSize = 20.0
  @ScaledMetric(relativeTo: .body) private var largeSize = 40.0
  var body: some View {
    inlineText.font(.body).textSelection(.enabled).accessibilityLabel(content.message)
      .contextMenu {
        Button(copyTitle) {
          #if os(macOS)
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(content.message, forType: .string)
          #else
          UIPasteboard.general.string = content.message
          #endif
        }
      }
      .task(id: content) {
        let requested = content
        let loaded = await withTaskGroup(of: (URL, CGImage?).self) { group in
          var iterator = requested.emotes.makeIterator()
          func enqueue(_ emote: CommentEmote) {
            group.addTask { (emote.url, try? await ThumbnailCache.shared.thumbnail(emote.url)) }
          }
          for _ in 0..<4 { if let emote = iterator.next() { enqueue(emote) } }
          var result: [URL: CGImage] = [:]
          for await (url, image) in group {
            if Task.isCancelled { group.cancelAll(); break }
            if let image { result[url] = image }
            if let next = iterator.next() { enqueue(next) }
          }
          return result
        }
        guard !Task.isCancelled else { return }
        images = loaded
      }
  }
  private var inlineText: Text {
    content.parts.reduce(Text("")) { accumulated, part in
      switch part {
      case .text(let value): return Text("\(accumulated)\(Text(verbatim: value))")
      case .emote(let emote):
        guard let image = images[emote.url] else { return Text("\(accumulated)\(Text(verbatim: emote.token))") }
        let size = emote.large ? largeSize : smallSize
        let ratio = min(2, max(0.5, Double(image.width) / Double(max(1, image.height))))
        #if os(macOS)
        let icon = NSImage(cgImage: image, size: NSSize(width: size * ratio, height: size))
        let attachment = Text(Image(nsImage: icon)).baselineOffset(emote.large ? -8 : -4)
        #else
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size * ratio, height: size))
        let icon = renderer.image { _ in UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: size * ratio, height: size)) }
        let attachment = Text(Image(uiImage: icon)).baselineOffset(emote.large ? -8 : -4)
        #endif
        return Text("\(accumulated)\(attachment)")
      }
    }
  }
}
