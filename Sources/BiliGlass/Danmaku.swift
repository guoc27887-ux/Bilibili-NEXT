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
  var error: String?
  var sending = false
  var sendError: String?
  var message = ""
  var mode = 1
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
    if let localSidecar, let data = try? Data(contentsOf: localSidecar),
      let saved = try? JSONDecoder().decode([Danmaku].self, from: data)
    {
      items = saved
      return
    }
    guard cid > 0 else { return }
    specialLoading = true
    specialTask = Task {
      do {
        let result = try await withDeadline(seconds: 60) { try await api.specialDanmaku(cid: cid, aid: aid) }
        guard token == current, !Task.isCancelled else { return }
        special = result
        needsRebuild = true
        specialLoading = false
      } catch {
        guard token == current, !Task.isCancelled else { return }
        specialError = "高级弹幕加载失败，重新打开视频可重试"
        specialLoading = false
      }
    }
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
  func stop() {
    task?.cancel()
    specialTask?.cancel()
    task = nil
    specialTask = nil
    token = UUID()
    localSent = []
    needsRebuild = false
    segments = [:]
    special = []
    specialError = nil
    specialLoading = false
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
    let time = player.currentTime().seconds
    guard time.isFinite else { return }
    sending = true
    sendError = nil
    defer { sending = false }
    do {
      let d = try await api.post(
        "/x/v2/dm/post",
        [
          "type": "1", "oid": "\(cid)", "aid": "\(aid)", "msg": text,
          "progress": "\(max(0,Int(time*1000)))", "color": "16777215", "fontsize": "25",
          "pool": "0", "mode": "\(mode)", "rnd": "\(Int64(Date().timeIntervalSince1970*1_000_000))",
        ])
      guard token == current else { return }
      message = ""
      if d["visible"] as? Bool != false {
        let item = Danmaku(
            id: d["dmid_str"] as? String ?? UUID().uuidString, time: time, mode: mode, size: 25,
            color: 16_777_215, text: text)
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
    var items: [Danmaku] = (try? await api.specialDanmaku(cid: cid)) ?? []
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
}
enum DanmakuLayout {
  static func prepare(
    items: [Danmaku], size: CGSize, scale: CGFloat, area: CGFloat, duration: Double, time: Double, topInset: CGFloat = 12
  ) -> [DanmakuPlacement] {
    let scale = max(0.5, scale)
    let rowHeight = 38 * scale
    let usableHeight = max(rowHeight, size.height - 100 - topInset)
    let totalLanes = max(1, Int(usableHeight / rowHeight))
    let lanes = max(1, min(totalLanes, Int(size.height * area / rowHeight)))
    var occupied = [[DanmakuPlacement]](repeating: [], count: totalLanes)
    var result: [DanmakuPlacement] = []
    for item in items where item.time >= max(0,time-20) && item.time <= time+60 && (1...6).contains(item.mode) {
      let font = NSFont.systemFont(ofSize: max(12,min(36,CGFloat(item.size)*scale)), weight: .semibold)
      let width = ceil((item.text as NSString).size(withAttributes:[.font:font]).width) + 6
      let rolling = ![4,5].contains(item.mode)
      let life = rolling ? duration : 4
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
        let placement = DanmakuPlacement(item:item,lane:lane,width:width,duration:life)
        occupied[lane].append(placement); result.append(placement)
      }
    }
    return result
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
  private var textLayers: [String: CATextLayer] = [:]
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
    specialTask?.cancel()
    specialRenderer.replace(SpecialCompilation())
    if let cache = compilationCache, cache.source == source {
      specialRenderer.replace(cache.compilation)
      lastTime = -1
      return
    }
    specialTask = Task { [weak self] in
      let compilation = await Task.detached(priority: .utility) { SpecialCompilation.compile(source) }.value
      guard let self, !Task.isCancelled else { return }
      compilationCache?.source = source
      compilationCache?.compilation = compilation
      specialRenderer.replace(compilation)
      onSpecialStatus?(compilation.scripts.count, compilation.unsupported)
      lastTime = -1
      tick()
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
  private func requestPlan(time: Double) {
    guard !planning, bounds.width > 0, bounds.height > 0 else { return }
    planning = true
    let token = revision
    let source = items
    let size = bounds.size
    let inset = topInset
    let scale = textScale
    let area = max(
      0.2, min(1, UserDefaults.standard.object(forKey: "danmakuArea") as? Double ?? 0.5))
    let duration = max(
      3, min(15, UserDefaults.standard.object(forKey: "danmakuDuration") as? Double ?? 8))
    task = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        DanmakuLayout.prepare(
          items: source, size: size, scale: scale, area: area, duration: duration, time: time, topInset: inset)
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
    let currentStyle = ["danmakuScale", "danmakuArea", "danmakuDuration", "danmakuOpacity"].map {
      String(describing: defaults.object(forKey: $0))
    }.joined(separator: ":")
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
      let text = item.text
      let opacity: Float = 1
      var x: CGFloat
      var y: CGFloat
      x = item.mode == 4 || item.mode == 5
        ? (bounds.width-placement.width)/2
        : item.mode == 6
          ? -placement.width+(bounds.width+placement.width)*elapsed/placement.duration
          : bounds.width-(bounds.width+placement.width)*elapsed/placement.duration
      y = topInset + CGFloat(placement.lane) * 38 * textScale
      visible.insert(item.id)
      let textLayer: CATextLayer
      if let existing = textLayers[item.id] {
        textLayer = existing
      } else {
        textLayer = CATextLayer()
        textLayer.anchorPoint = .zero
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        let font = NSFont.systemFont(
          ofSize: max(12, min(36, CGFloat(item.size) * textScale)), weight: .semibold)
        let color = NSColor(
          srgbRed: CGFloat((item.color >> 16) & 255) / 255,
          green: CGFloat((item.color >> 8) & 255) / 255, blue: CGFloat(item.color & 255) / 255,
          alpha: 1)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 1; shadow.shadowOffset = CGSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [
          .font: font, .foregroundColor: color, .shadow: shadow,
        ]
        textLayer.string = NSAttributedString(string: text, attributes: attributes)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        textLayer.bounds = CGRect(x: 0, y: 0, width: width + 8, height: font.pointSize * 1.6)
        // Text and its shadow are drawn together once; motion only composites the bitmap.
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
  func specialDanmaku(cid: Int, aid: Int = 0) async throws -> [Danmaku] {
    let metadata = try await binary(
      "/x/v2/dm/web/view", ["type": "1", "oid": "\(cid)", "pid": "\(aid)"])
    var reader = ProtoReader(bytes: Array(metadata))
    var urls: [URL] = []
    while let field = try reader.field() {
      if field.0 == 6, let raw = field.2, let text = String(bytes: raw, encoding: .utf8),
        let url = Self.specialDanmakuURL(text)
      {
        urls.append(url)
      }
    }
    var items: [Danmaku] = []
    for url in urls.prefix(20) {
      try Task.checkCancellation()
      var req = URLRequest(url: url)
      Self.mediaHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
      let (data, r) = try await URLSession.shared.data(for: req)
      guard (r as? HTTPURLResponse)?.statusCode == 200, data.count < 32 * 1024 * 1024 else {
        continue
      }
      items += (try? ProtoReader.decode(data)) ?? []
    }
    return items
  }
}
