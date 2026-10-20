import AVFoundation
import AppKit
import SwiftUI

struct Danmaku: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let time: Double
  let mode: Int
  let size: Int
  let color: Int
  let text: String
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
      while let f = try elem.field() {
        switch f.0 {
        case 1: id = "\(f.1 ?? 0)"
        case 2: time = Double(f.1 ?? 0) / 1000
        case 3: mode = Int(clamping: f.1 ?? 1)
        case 4: size = Int(clamping: f.1 ?? 25)
        case 5: color = Int(clamping: f.1 ?? 16_777_215)
        case 7: text = String(bytes: f.2 ?? [], encoding: .utf8) ?? ""
        case 12: id = String(bytes: f.2 ?? [], encoding: .utf8) ?? id
        default: break
        }
      }
      if !text.isEmpty && time.isFinite {
        items.append(Danmaku(id: id, time: time, mode: mode, size: size, color: color, text: text))
      }
    }
    return items.sorted { $0.time < $1.time }
  }
}
@MainActor @Observable final class DanmakuController {
  var items: [Danmaku] = []
  var special: [Danmaku] = []
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
  static func xml(_ items: [Danmaku], cid: Int) -> String {
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

struct DanmakuPlacement: Sendable {
  let item: Danmaku
  let lane: Int
  let width: CGFloat
  let duration: Double
  let y: CGFloat
  let fontSize: CGFloat
  let height: CGFloat
}
struct DanmakuDisplayOptions: Sendable {
  var scrolling = true
  var top = true
  var bottom = true
  var colored = true
  var avoidSubtitles = true
  var deduplicate = false
  var blockedWords: [String] = []
  func accepts(_ item: Danmaku) -> Bool {
    guard (1...6).contains(item.mode), colored || item.color == 0xFFFFFF else { return false }
    guard !blockedWords.contains(where: { !$0.isEmpty && item.text.localizedCaseInsensitiveContains($0) }) else { return false }
    switch item.mode { case 4: return bottom; case 5: return top; default: return scrolling }
  }
  static func read(_ defaults: UserDefaults = .standard) -> Self {
    func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
    return Self(scrolling: flag("danmakuScrolling", true), top: flag("danmakuTop", true),
      bottom: flag("danmakuBottom", true), colored: flag("danmakuColored", true),
      avoidSubtitles: flag("danmakuAvoidSubtitles", true), deduplicate: flag("danmakuDeduplicate", false),
      blockedWords: (defaults.string(forKey: "danmakuBlockedWords") ?? "").split(separator: "\n").map(String.init))
  }
}
enum DanmakuLayout {
  static func prepare(
    items: [Danmaku], size: CGSize, scale: CGFloat, area: CGFloat, duration: Double, time: Double,
    topInset: CGFloat = 12, bottomInset: CGFloat = 12, options: DanmakuDisplayOptions = .init()
  ) -> [DanmakuPlacement] {
    guard size.width > 0, size.height > topInset else { return [] }
    let scale = max(0.5, min(2, scale))
    let source = items.filter { $0.time >= max(0,time-20) && $0.time <= time+60 && options.accepts($0) }
      .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    func fontSize(_ item: Danmaku) -> CGFloat { max(12, min(72, CGFloat(max(12, min(36, item.size))) * scale)) }
    let largest = source.map(fontSize).max() ?? 25 * scale
    let font = NSFont.systemFont(ofSize: largest, weight: .semibold)
    let rowHeight = ceil(max(38 * scale, font.ascender - font.descender + font.leading + 8))
    let bottom = max(bottomInset, options.avoidSubtitles ? size.height * 0.15 : 0)
    let usableHeight = max(0, size.height - bottom - topInset)
    let totalLanes = Int(usableHeight / rowHeight)
    guard totalLanes > 0 else { return [] }
    let lanes = max(1, min(totalLanes, Int(ceil(CGFloat(totalLanes) * max(0.2, min(1, area))))))
    var occupied = [[DanmakuPlacement]](repeating: [], count: totalLanes)
    var result: [DanmakuPlacement] = []
    var lastText: [String: Double] = [:]
    for item in source {
      if options.deduplicate, let previous = lastText[item.text], item.time - previous < duration { continue }
      let pointSize = fontSize(item)
      let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
      let text = displayText(item.text)
      let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8
      let height = ceil(font.ascender - font.descender + font.leading) + 4
      let rolling = ![4,5].contains(item.mode)
      let life = rolling ? max(3, duration) : 4
      let candidates = item.mode == 4 ? Array((totalLanes-lanes..<totalLanes).reversed()) : Array(0..<lanes)
      if let lane = candidates.first(where: { lane in
        occupied[lane].removeAll { $0.item.time+$0.duration <= item.time }
        return occupied[lane].allSatisfy { prior in
          guard rolling, ![4,5].contains(prior.item.mode), (prior.item.mode == 6) == (item.mode == 6) else { return false }
          let elapsed = item.time-prior.item.time
          let velocity = (size.width+width)/life, oldVelocity = (size.width+prior.width)/prior.duration
          return oldVelocity*elapsed >= prior.width+20 &&
            (velocity <= oldVelocity || velocity*(prior.duration-elapsed) <= size.width-20)
        }
      }) {
        let placement = DanmakuPlacement(item: item, lane: lane, width: width, duration: life,
          y: topInset + CGFloat(lane) * rowHeight, fontSize: pointSize, height: height)
        occupied[lane].append(placement); result.append(placement); lastText[item.text] = item.time
      }
    }
    return result
  }
  static func displayText(_ raw: String) -> String {
    String(raw.prefix(1000)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
  }
}
@MainActor final class SpecialDanmakuCache {
  var source: [Danmaku] = []
  var compilation = SpecialCompilation()
}
@MainActor final class DanmakuView: NSView {
  var player: AVPlayer? { didSet { if player !== oldValue { observePlayer(oldValue) } } }
  private var controlObservation: NSKeyValueObservation?
  private var rateObservation: NSKeyValueObservation?
  private var playerTimeObserver: Any?
  private var visibilityObservers: [NSObjectProtocol] = []
  private var defaultsObserver: NSObjectProtocol?
  private var wakeTask: Task<Void, Never>?
  private var clockTicks = 0
  var compilationCache: SpecialDanmakuCache?
  var items: [Danmaku] = [] { didSet { invalidatePlan(); compileSpecial() } }
  let specialRenderer = SpecialDanmakuRenderer()
  var onSpecialStatus: ((Int, Int) -> Void)?
  private var specialTask: Task<Void, Never>?
  private var specialSource: [Danmaku] = []
  private var plannedSize = CGSize.zero
  var enabled = true { didSet { if enabled != oldValue { refreshClock() } } }
  var bottomInset: CGFloat = 12 { didSet { if bottomInset != oldValue { invalidatePlan(); lastTime = -1 } } }
  var topInset: CGFloat = 12 { didSet { if topInset != oldValue { invalidatePlan(); lastTime = -1 } } }
  private var frameLink: CADisplayLink?
  @MainActor private final class FrameTarget: NSObject {
    weak var view: DanmakuView?
    @objc func frame(_ link: CADisplayLink) { view?.clockTicks += 1; view?.tick() }
  }
  private let frameTarget = FrameTarget()
  private var task: Task<Void, Never>?
  private var revision = UUID()
  private var plannedWidth: CGFloat = -1
  private var windowStart = -1.0
  private var windowEnd = -1.0
  private var plan: [DanmakuPlacement] = []
  private var textLayers: [String: CALayer] = [:]
  private var lastTime = -1.0
  private var planning = false
  private var style = ""
  private var sampleStart = CACurrentMediaTime()
  private var sampleFrames = 0
  private var sampleRenderTime = 0.0
  private var measuredFPS = 0.0
  private var meanRenderMilliseconds = 0.0
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = true
    layer?.isGeometryFlipped = true
    layer?.addSublayer(specialRenderer.root)
    specialRenderer.didPrepare = { [weak self] in self?.lastTime = -1; self?.tick() }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.style != self.currentStyle else { return }
        self.refreshClock()
      }
    }
    frameTarget.view = self
    let link = displayLink(target: frameTarget, selector: #selector(FrameTarget.frame(_:)))
    link.isPaused = true
    link.add(to: .main, forMode: .common)
    frameLink = link
  }
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit {
    frameLink?.invalidate()
    wakeTask?.cancel()
    visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
    if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    if let playerTimeObserver { player?.removeTimeObserver(playerTimeObserver) }
    task?.cancel()
    specialTask?.cancel()
  }
  func statistics() -> [String: Any] {
    [
      "displayLinkPaused": frameLink?.isPaused ?? true, "clockTicks": clockTicks,
      "items": items.count, "planned": plan.count, "layers": textLayers.count,
      "specialLayers": specialRenderer.count, "specialScripts": specialRenderer.compilation.scripts.count, "unsupportedScripts": specialRenderer.compilation.unsupported,
      "width": bounds.width, "height": bounds.height, "visible": !visibleRect.isEmpty,
      "attached": superview != nil, "window": window != nil,
      "measuredFPS": measuredFPS, "meanRenderMilliseconds": meanRenderMilliseconds,
      "displayMaximumFPS": window?.screen?.maximumFramesPerSecond ?? 0,
      "parentWidth": superview?.bounds.width ?? 0, "parentHeight": superview?.bounds.height ?? 0,
    ]
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let rate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
    frameLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60,rate), maximum: rate, preferred: rate)
    visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
    visibilityObservers = []
    if let window {
      visibilityObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.refreshClock() }
      })
    }
    if let clip = enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      visibilityObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.refreshClock() }
      })
    }
    lastTime = -1
    refreshClock()
  }
  private func observePlayer(_ old: AVPlayer?) {
    if let playerTimeObserver { old?.removeTimeObserver(playerTimeObserver) }
    playerTimeObserver = nil; controlObservation = nil; rateObservation = nil
    if let player {
      controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.refreshClock() }
      }
      rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.refreshClock() }
      }
      playerTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { if self?.frameLink?.isPaused == true { self?.refreshClock() } }
      }
    }
    lastTime = -1
    refreshClock()
  }
  private func refreshClock() { wakeTask?.cancel(); wakeTask = nil; lastTime = -1; tick() }
  override func layout() { super.layout(); refreshClock() }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {}
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard enabled, !isHidden else { return nil }
    return specialRenderer.hit(convert(point, from: superview)) == nil ? nil : self
  }
  override func mouseDown(with event: NSEvent) {
    if let target = specialRenderer.hit(convert(event.locationInWindow, from: nil)) {
      if case .object("seek", let values) = target, let raw = values["time"]?.scalar,
        let duration = player?.currentItem?.duration.seconds, duration.isFinite {
        player?.seek(to: CMTime(seconds: min(duration,max(0,raw)), preferredTimescale: 600))
      } else { specialRenderer.activate?(target) }
    }
  }
  private func compileSpecial() {
    let source = items.filter { [7,8,9].contains($0.mode) }
    guard source != specialSource else { return }
    specialSource = source
    if source.isEmpty {
      specialTask?.cancel(); specialTask = nil
      specialRenderer.replace(SpecialCompilation())
      return
    }
    if let cache = compilationCache, cache.source == source {
      specialTask?.cancel(); specialTask = nil
      specialRenderer.replace(cache.compilation)
      lastTime = -1; tick()
      return
    }
    guard specialTask == nil else { return }
    specialTask = Task { [weak self] in
      while let self, !Task.isCancelled {
        let pending = specialSource
        let previous = specialRenderer.compilation
        let worker = Task.detached(priority: .utility) { SpecialCompilation.compile(pending, reusing: previous) }
        let compilation = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        compilationCache?.source = pending
        compilationCache?.compilation = compilation
        specialRenderer.replace(compilation)
        onSpecialStatus?(compilation.scripts.count, compilation.unsupported)
        lastTime = -1; tick()
        if pending == specialSource { specialTask = nil; return }
      }
    }
  }
  private var textScale: CGFloat {
    max(0.5, min(2, UserDefaults.standard.object(forKey: "danmakuScale") as? Double ?? 1))
  }
  private func invalidatePlan() {
    revision = UUID()
    task?.cancel()
    planning = false
    plannedWidth = -1
  }
  private var currentStyle: String {
    ["danmakuScale", "danmakuArea", "danmakuDuration", "danmakuOpacity", "danmakuScrolling",
      "danmakuTop", "danmakuBottom", "danmakuColored", "danmakuAvoidSubtitles",
      "danmakuDeduplicate", "danmakuBlockedWords"].map {
        String(describing: UserDefaults.standard.object(forKey: $0))
      }.joined(separator: ":")
  }
  private func requestPlan(time: Double) {
    guard !planning, bounds.width > 0, bounds.height > 0 else { return }
    planning = true
    let token = revision
    let source = items
    let size = bounds.size
    let inset = topInset, bottom = bottomInset
    let options = DanmakuDisplayOptions.read()
    let scale = textScale
    let area = max(
      0.2, min(1, UserDefaults.standard.object(forKey: "danmakuArea") as? Double ?? 0.5))
    let duration = max(
      3, min(15, UserDefaults.standard.object(forKey: "danmakuDuration") as? Double ?? 8))
    task = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        DanmakuLayout.prepare(
          items: source, size: size, scale: scale, area: area, duration: duration, time: time, topInset: inset, bottomInset: bottom, options: options)
      }.value
      guard let self, !Task.isCancelled, token == revision else { return }
      guard size == bounds.size else {
        planning = false
        return
      }
      plan = result
      plannedWidth = size.width
      plannedSize = size
      windowStart = max(0, time - 20)
      windowEnd = time + 60
      planning = false
      lastTime = -1
      tick()
    }
  }
  private func tick() {
    guard enabled, !isHiddenOrHasHiddenAncestor, window?.isVisible == true, window?.occlusionState.contains(.visible) == true, !visibleRect.isEmpty, let player else {
      if !textLayers.isEmpty {
        textLayers.values.forEach { $0.removeFromSuperlayer() }
        textLayers = [:]
      }
      if specialRenderer.count > 0 { specialRenderer.clear() }
      frameLink?.isPaused = true
      wakeTask?.cancel(); wakeTask = nil
      lastTime = -1
      return
    }
    let defaults = UserDefaults.standard
    let currentStyle = self.currentStyle
    if currentStyle != style {
      style = currentStyle
      invalidatePlan()
      textLayers.values.forEach { $0.removeFromSuperlayer() }
      textLayers = [:]
      lastTime = -1
    }
    guard player.timeControlStatus != .waitingToPlayAtSpecifiedRate else { frameLink?.isPaused = true; return }
    let time = player.currentTime().seconds
    guard time.isFinite else { return }
    if plannedWidth != bounds.width || plannedSize != bounds.size || time < windowStart || time > windowEnd - 10 {
      requestPlan(time: time)
    }
    let hasVisible = plan.contains { $0.item.time <= time && time < $0.item.time + $0.duration }
      || specialRenderer.compilation.scripts.contains { $0.item.time <= time && time < $0.item.time + $0.duration }
    frameLink?.isPaused = player.timeControlStatus != .playing || !hasVisible
    if !hasVisible, player.timeControlStatus == .playing, wakeTask == nil,
       let next = items.lazy.filter({ $0.time > time }).map(\.time).min() {
      let delay = min(60, max(0.001, (next - time) / Double(max(0.1, player.rate))))
      wakeTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        self?.wakeTask = nil; self?.tick()
      }
    }
    if !hasVisible && textLayers.isEmpty && specialRenderer.count == 0 { lastTime = time; return }
    guard time != lastTime || plannedSize != bounds.size else { return }
    lastTime = time
    let renderStart = CACurrentMediaTime()
    defer {
      let now = CACurrentMediaTime()
      if player.rate == 0 { sampleStart = now; sampleFrames = 0; sampleRenderTime = 0 }
      else {
        sampleFrames += 1; sampleRenderTime += now-renderStart
        if now-sampleStart >= 2 {
          measuredFPS = Double(sampleFrames)/(now-sampleStart)
          meanRenderMilliseconds = sampleRenderTime*1000/Double(sampleFrames)
          sampleStart = now; sampleFrames = 0; sampleRenderTime = 0
        }
      }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    specialRenderer.render(time: time, size: bounds.size, backingScale: window?.backingScaleFactor ?? 2,
      opacity: Float(max(0.1,min(1,defaults.object(forKey:"danmakuOpacity") as? Double ?? 0.85))))
    var visible = Set<String>()
    for placement in plan
    where placement.item.time <= time && time - placement.item.time < placement.duration {
      guard visible.count < 150 else { break }
      let item = placement.item
      let elapsed = time - item.time
      let text = DanmakuLayout.displayText(item.text)
      let opacity: Float = 1
      var x: CGFloat
      var y: CGFloat
      x = item.mode == 4 || item.mode == 5
        ? (bounds.width-placement.width)/2
        : item.mode == 6
          ? -placement.width+(bounds.width+placement.width)*elapsed/placement.duration
          : bounds.width-(bounds.width+placement.width)*elapsed/placement.duration
      y = placement.y
      visible.insert(item.id)
      let textLayer: CALayer
      if let existing = textLayers[item.id] {
        textLayer = existing
      } else {
        textLayer = CALayer()
        textLayer.anchorPoint = .zero
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        textLayer.bounds = CGRect(x: 0, y: 0, width: placement.width, height: placement.height)
        textLayer.contents = DanmakuTextBitmap.make(text: text, fontSize: placement.fontSize, color: item.color,
          size: textLayer.bounds.size, scale: textLayer.contentsScale)
        // The outline and solid fill share one cached bitmap, including on a flipped layer.
        layer?.addSublayer(textLayer)
        textLayers[item.id] = textLayer
      }
      textLayer.opacity =
        opacity
        * Float(
          max(
            0.1, min(1, UserDefaults.standard.object(forKey: "danmakuOpacity") as? Double ?? 0.85)))
      textLayer.position = CGPoint(x: x, y: y)
    }
    for id in Array(textLayers.keys) where !visible.contains(id) {
      textLayers.removeValue(forKey: id)?.removeFromSuperlayer()
    }
  }
}

struct DanmakuOverlay: NSViewRepresentable {
  let player: AVPlayer
  let items: [Danmaku]
  let enabled: Bool
  func makeNSView(context: Context) -> DanmakuView {
    let v = DanmakuView()
    v.player = player
    return v
  }
  func updateNSView(_ view: DanmakuView, context: Context) {
    view.player = player
    if view.items != items {
      view.items = items
    }
    view.enabled = enabled
    view.isHidden = !enabled
    view.needsDisplay = true
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
