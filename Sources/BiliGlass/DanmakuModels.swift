import Foundation
import AVFoundation
import SwiftUI

struct Danmaku: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let time: Double
  let mode: Int
  let size: Int
  let color: Int
  let text: String
  var senderHash: String? = nil
}
struct ProtoReader {
  let bytes: [UInt8]
  var offset = 0
  mutating func varint() throws -> UInt64 {
    var result: UInt64 = 0
    for shift in stride(from: 0, to: 64, by: 7) {
      guard offset < bytes.count else { throw BiliError(text: "弹幕数据不完整") }
      let b = bytes[offset]
      offset += 1
      if shift == 63 && b > 1 { throw BiliError(text: "弹幕数据无效") }
      result |= UInt64(b & 127) << shift
      if b & 128 == 0 { return result }
    }
    throw BiliError(text: "弹幕数据无效")
  }
  mutating func field() throws -> (Int, UInt64?, [UInt8]?)? {
    guard offset < bytes.count else { return nil }
    let key = try varint()
    let number = Int(key >> 3)
    guard number > 0 else { throw BiliError(text: "弹幕数据无效") }
    switch key & 7 {
    case 0: return (number, try varint(), nil)
    case 1:
      guard offset + 8 <= bytes.count else { throw BiliError(text: "弹幕数据不完整") }
      offset += 8
      return (number, nil, nil)
    case 2:
      let length = try varint()
      guard length <= UInt64(bytes.count - offset) else { throw BiliError(text: "弹幕数据不完整") }
      let data = Array(bytes[offset..<offset + Int(length)])
      offset += Int(length)
      return (number, nil, data)
    case 5:
      guard offset + 4 <= bytes.count else { throw BiliError(text: "弹幕数据不完整") }
      offset += 4
      return (number, nil, nil)
    default: throw BiliError(text: "弹幕数据无效")
    }
  }
  static func decode(_ data: Data) throws -> [Danmaku] {
    var reader = ProtoReader(bytes: Array(data))
    var items: [Danmaku] = []
    while let field = try reader.field() {
      guard field.0 == 1, let bytes = field.2 else { continue }
      var elem = ProtoReader(bytes: bytes)
      var id = ""
      var time = 0.0
      var mode = 1
      var size = 25
      var color = 16_777_215
      var text = ""
      var senderHash: String?
      while let f = try elem.field() {
        switch f.0 {
        case 1: id = "\(f.1 ?? 0)"
        case 2: time = Double(f.1 ?? 0) / 1000
        case 3: mode = Int(clamping: f.1 ?? 1)
        case 4: size = Int(clamping: f.1 ?? 25)
        case 5: color = Int(clamping: f.1 ?? 16_777_215)
        case 6: senderHash = String(bytes: f.2 ?? [], encoding: .utf8)
        case 7: text = String(bytes: f.2 ?? [], encoding: .utf8) ?? ""
        case 12: id = String(bytes: f.2 ?? [], encoding: .utf8) ?? id
        default: break
        }
      }
      if !text.isEmpty && time.isFinite {
        items.append(Danmaku(id: id, time: time, mode: mode, size: size, color: color, text: text, senderHash: senderHash))
      }
    }
    return items.sorted { $0.time < $1.time }
  }
}

@MainActor @Observable final class DanmakuController {
  var items: [Danmaku] = []
  var special: [Danmaku] = []
  var historyDate: String?
  var specialError: String?
  var specialLoading = false
  var specialProgress = ""
  var error: String?
  var sending = false
  var sendError: String?
  var message = ""
  var mode = 1
  var color = 0xFFFFFF
  var fontSize = 25
  var enabled = UserDefaults.standard.object(forKey: "danmakuEnabled") as? Bool ?? true
  private var segments: [Int: [Danmaku]] = [:]
  private var localSent: [Danmaku] = []
  private var needsRebuild = false
  private var inFlight = Set<Int>()
  private var task: Task<Void, Never>?
  private var specialTask: Task<Void, Never>?
  private var token = UUID()
  private var cid = 0
  func start(cid: Int, aid: Int = 0, api: API, player: AVPlayer, localSidecar: URL? = nil) {
    stop()
    self.cid = cid
    let current = token
    if let localSidecar {
      task = Task {
        let saved = await Task.detached(priority: .userInitiated) {
          guard let data = try? Data(contentsOf: localSidecar) else { return Optional<[Danmaku]>.none }
          return try? JSONDecoder().decode([Danmaku].self, from: data)
        }.value
        guard token == current, !Task.isCancelled else { return }
        if let saved { items = Self.merged(saved) }
        else { start(cid: cid, aid: aid, api: api, player: player) }
      }
      return
    }
    guard cid > 0 else { return }
    loadSpecial(cid: cid, aid: aid, api: api, current: current)
    task = Task {
      while !Task.isCancelled, token == current {
        let time = player.currentTime().seconds
        let segment = max(1, Int((time.isFinite ? time : 0) / 360) + 1)
        let threads = 2
        let wanted = (segment..<(segment + threads)).filter {
          segments[$0] == nil && !inFlight.contains($0)
        }
        // Small bounded group, tied to this video identity; stale results are discarded.
        for index in wanted { inFlight.insert(index) }
        await withTaskGroup(of: (Int, [Danmaku]?, String?).self) { group in
          for index in wanted {
            group.addTask { @MainActor in
              do {
                let data = try await api.binary(
                  "/x/v2/dm/web/seg.so",
                  ["type": "1", "oid": "\(cid)", "segment_index": "\(index)"])
                let parsed = try await Task.detached { try ProtoReader.decode(data) }.value
                return (index, parsed, nil)
              } catch { return (index, nil, error.localizedDescription) }
            }
          }
          for await (index, data, failure) in group {
            guard token == current else { continue }
            inFlight.remove(index)
            if let data {
              segments[index] = data
              needsRebuild = true
              error = nil
            } else if index == segment {
              error = failure
            }
          }
        }
        guard token == current else { return }
        if segments.count > 8 { segments = segments.filter { abs($0.key - segment) <= 3 }; needsRebuild = true }
        if needsRebuild {
          needsRebuild = false
          let source = segments.values.flatMap { $0 } + special + localSent
          let merged = await Task.detached { Self.merged(source) }.value
          guard token == current, !Task.isCancelled else { return }
          if merged != items { items = merged }
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
  func retrySpecial(aid: Int, api: API) {
    guard cid > 0, !specialLoading else { return }
    loadSpecial(cid: cid, aid: aid, api: api, current: token)
  }
  private func loadSpecial(cid: Int, aid: Int, api: API, current: UUID) {
    specialTask?.cancel()
    specialLoading = true
    specialError = nil
    specialTask = Task { [self] in
      do {
        _ = try await api.specialDanmaku(cid: cid, aid: aid) { batch, completed, total in
          guard self.token == current, !Task.isCancelled else { return }
          self.special = Self.merged(self.special + batch)
          self.specialProgress = "高级弹幕 \(completed)/\(total)"
          self.needsRebuild = true
        }
      } catch {
        guard token == current, !Task.isCancelled else { return }
        specialError = special.isEmpty ? "高级弹幕加载失败" : "部分高级弹幕未加载，已加载内容可继续播放"
      }
      guard token == current, !Task.isCancelled else { return }
      specialLoading = false
      specialProgress = ""
    }
  }
  func stop() {
    historyDate = nil
    task?.cancel()
    specialTask?.cancel()
    task = nil
    specialTask = nil
    token = UUID()
    cid = 0
    sending = false
    localSent = []
    needsRebuild = false
    segments = [:]
    special = []
    specialError = nil
    specialLoading = false
    specialProgress = ""
    inFlight = []
    items = []
    error = nil
    message = ""
    sendError = nil
  }
  func send(aid: Int, api: API, player: AVPlayer) async {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sending, !text.isEmpty, text.count <= 100, cid > 0 else { return }
    let current = token
    let cid = cid
    let mode = mode, color = color, fontSize = fontSize
    let time = player.currentTime().seconds
    guard time.isFinite else { return }
    sending = true
    sendError = nil
    defer { if token == current { sending = false } }
    do {
      let d = try await api.post(
        "/x/v2/dm/post",
        [
          "type": "1", "oid": "\(cid)", "aid": "\(aid)", "msg": text,
          "progress": "\(max(0,Int(time*1000)))", "color": "\(color)", "fontsize": "\(fontSize)",
          "pool": "0", "mode": "\(mode)", "rnd": "\(Int64(Date().timeIntervalSince1970*1_000_000))",
        ])
      guard token == current else { return }
      message = ""
      if d["visible"] as? Bool != false {
        let item = Danmaku(
            id: d["dmid_str"] as? String ?? UUID().uuidString, time: time, mode: mode, size: fontSize,
            color: color, text: text)
        localSent.append(item)
        items = Self.merged(items + [item])
      }
    } catch { if token == current { sendError = error.localizedDescription } }
  }
  nonisolated static func merged(_ source: [Danmaku]) -> [Danmaku] {
    var seen = Set<String>()
    return source.filter { seen.insert($0.id).inserted }.sorted {
      $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time
    }
  }
  static func all(cid: Int, duration: Int, api: API) async throws -> [Danmaku] {
    var items: [Danmaku] = try await api.specialDanmaku(cid: cid)
    let count = max(1, Int(ceil(Double(duration) / 360)))
    guard count <= 1000 else { throw BiliError(text: "视频过长，请分集下载弹幕") }
    for index in 1...count {
      try Task.checkCancellation()
      let data = try await api.binary(
        "/x/v2/dm/web/seg.so", ["type": "1", "oid": "\(cid)", "segment_index": "\(index)"])
      items += try await Task.detached { try ProtoReader.decode(data) }.value
    }
    var ids = Set<String>()
    return items.filter { ids.insert($0.id).inserted }.sorted { $0.time < $1.time }
  }
  nonisolated static func xml(_ items: [Danmaku], cid: Int) -> String {
    func escape(_ s: String) -> String {
      s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
    }
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><i><chatid>\(cid)</chatid>"
      + items.map {
        "<d p=\"\($0.time),\($0.mode),\($0.size),\($0.color),0,0,,\(escape($0.id))\">\(escape($0.text))</d>"
      }.joined() + "</i>"
  }
}


extension API {
  nonisolated static func specialDanmakuURL(_ raw: String) -> URL? {
    guard var parts = URLComponents(string: raw.hasPrefix("//") ? "https:"+raw : raw) else { return nil }
    if parts.scheme == "http" { parts.scheme = "https" }
    guard parts.scheme == "https", let host = parts.host?.lowercased(),
      host == "hdslb.com" || host.hasSuffix(".hdslb.com"), parts.user == nil, parts.password == nil else { return nil }
    return parts.url
  }
  func specialDanmaku(cid: Int, aid: Int = 0,
    onBatch: (@MainActor ([Danmaku], Int, Int) -> Void)? = nil
  ) async throws -> [Danmaku] {
    let metadata = try await binary(
      "/x/v2/dm/web/view", ["type": "1", "oid": "\(cid)", "pid": "\(aid)"])
    var reader = ProtoReader(bytes: Array(metadata))
    var urls: [URL] = []
    while let field = try reader.field() {
      if field.0 == 6, let raw = field.2, let text = String(bytes: raw, encoding: .utf8),
        let url = Self.specialDanmakuURL(text), !urls.contains(url) { urls.append(url) }
    }
    var items: [Danmaku] = []
    var failures = 0
    // Each package has its own deadline. A slow later package never discards earlier data.
    for (index, url) in urls.prefix(40).enumerated() {
      try Task.checkCancellation()
      var batch: [Danmaku]?
      for _ in 0..<2 {
        do {
          batch = try await withDeadline(seconds: 40) {
            var req = URLRequest(url: url, timeoutInterval: 20)
            Self.mediaHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (data, response) = try await self.session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 32 * 1024 * 1024 else {
              throw BiliError(text: "高级弹幕数据无效")
            }
            return try await Task.detached(priority: .utility) { try ProtoReader.decode(data) }.value
          }
          break
        } catch {
          try Task.checkCancellation()
        }
      }
      if let batch { items += batch } else { failures += 1 }
      onBatch?(batch ?? [], index + 1, min(40, urls.count))
    }
    if failures > 0 || urls.count > 40 { throw BiliError(text: "部分高级弹幕加载失败") }
    return items
  }
}
