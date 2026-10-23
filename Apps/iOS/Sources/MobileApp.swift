import AVKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import WebKit

typealias MobileDanmaku = DanmakuController

/// Session setup can wait for audio routing; keep it off the interface executor.
private actor MobileAudioSession {
  static let shared = MobileAudioSession()
  func activate() async throws {
    let audio = AVAudioSession.sharedInstance()
    try audio.setCategory(.playback, mode: .moviePlayback)
    if #available(iOS 27, *) {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        audio.activate(options: []) { active, error in
          if let error {
            continuation.resume(throwing: error)
          } else if active {
            continuation.resume()
          } else {
            continuation.resume(throwing: BiliError(text: "音频输出未能激活"))
          }
        }
      }
    } else {
      try audio.setActive(true)
    }
  }
}

struct HistoryEntry: Codable, Identifiable {
  var id: String { "\(accountID ?? "legacy"):\(video.bvid)" }
  var video: Video
  var positions: [String: Double]
  var date: Date
  var lastCID: Int?
  var accountID: String?
}
struct WebTarget: Identifiable {
  let id = UUID()
  let url: URL
  let title: String
}
@MainActor @Observable final class Store {
  let api: API
  let playback = Playback()
  let mobilePiP = MobilePiPSession()
  let downloads = Downloads()
  let extras = VideoExtras()
  var comments = Comments()
  let playerNavigation = MobilePlayerNavigation()
  let actions = VideoActionsModel()
  let inbox = InboxModel()
  let accountHistory = AccountHistory()
  let historySync = WatchHistorySync()
  let danmaku = MobileDanmaku()
  var account: Account?
  var restoring = true
  var specialScripts = 0
  var specialLayers = 0
  var unsupportedScripts = 0
  var favoriteRevision = 0
  var danmakuPerformance: [String: Double] = [:]
  var orientationDiagnostics: [String: String] = [:]
  var showPlayer = false
  var conversationPresented = false
  var isPlaybackOpen = false
  var showLogin = false
  var webTarget: WebTarget?
  var message: String?
  var qrImage: CGImage?
  var loginStatus = ""
  var loginExpired = false
  var history: [HistoryEntry] = []
  var queue: [PlaybackQueueItem] = []
  private var loginTask: Task<Void, Never>?
  private var qaTask: Task<Void, Never>?
  private var qaTransferSamples: [[String: Any]] = []
  private var audioTask: Task<Void, Never>?
  private var audioNotifications: [NSObjectProtocol] = []
  init() {
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    #if DEBUG
      api =
        MobileFavoriteFixture.enabled
        ? MobileFavoriteFixture.makeAPI()
        : MobileUIFixture.enabled ? MobileUIFixture.makeAPI() : API(loadCredentials: false)
    #else
      api = API(loadCredentials: false)
    #endif
    UserDefaults.standard.register(defaults: [
      "appearance": "system", "videoThreads": 4, "continuousPreload": true,
      "bufferSeconds": 15.0, "rememberPosition": true, "syncWatchHistory": true, "autoPlay": true,
      "videoCodecPreference": "hevc", "downloadThreads": 4, "simultaneousDownloads": 1,
      "danmakuEnabled": true,
    ])
    if let data = UserDefaults.standard.data(forKey: "history") {
      history = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }
    playback.onProgress = { [weak self] bvid, cid, seconds, final in
      self?.save(bvid, cid: cid, seconds: seconds, final: final)
    }
    playback.onEnded = { [weak self] in
      guard let self else { return }
      if UserDefaults.standard.bool(forKey: "loopVideo") {
        self.playback.seek(to: 0)
        self.playback.player.playImmediately(atRate: self.playback.speed)
      } else if UserDefaults.standard.bool(forKey: "autoPlayNext") {
        self.next()
      }
    }
    audioNotifications.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        Task { @MainActor in
          guard let self else { return }
          self.playback.endTemporarySpeed()
          if type == AVAudioSession.InterruptionType.began.rawValue {
            self.playback.player.pause()
            self.playback.saveCurrentProgress()
          }
        }
      })
    audioNotifications.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] note in
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
          Task { @MainActor in
            self?.playback.player.pause()
            self?.playback.saveCurrentProgress()
          }
        }
      })
  }
  func start() async {
    #if DEBUG
      if MobileUIFixture.enabled {
        account = Account(name: "本地测试", mid: 1, face: "")
        restoring = false
        if ProcessInfo.processInfo.arguments.contains("--qa-navigation") { open("BV1xx411c7mD") }
        if ProcessInfo.processInfo.arguments.contains("--qa-capture") {
          qaTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            MobileUIFixture.captureInterface()
          }
        }
        return
      }
      if MobileFavoriteFixture.enabled {
        account = Account(name: "本地测试", mid: 1, face: "")
        restoring = false
        let detail = Detail(
          video: Video(
            bvid: "BV1xx411c7mD", title: "收藏保存测试", cover: "",
            author: "本地测试", duration: 0, views: 0), description: "", pages: [], aid: 123)
        playback.detail = detail
        await actions.load(detail: detail, accountID: 1, api: api)
        showPlayer = true
        return
      }
    #endif
    PlaybackTemporaryFiles.cleanup()
    await api.restoreCredentials()
    account = try? await api.nav()
    restoring = false
    let args = ProcessInfo.processInfo.arguments
    var qa = false
    #if DEBUG
      if let i = args.firstIndex(of: "--qa-connections"), args.indices.contains(i + 1), let count = Int(args[i + 1]) { playback.connectionOverride = max(1, min(32, count)) }
      if let i = args.firstIndex(of: "--qa-fixture"), args.indices.contains(i + 1),
        args[i + 1] == (args[i + 1] as NSString).lastPathComponent
      {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("QA").appendingPathComponent(args[i + 1])
        if FileManager.default.fileExists(atPath: file.path) {
          activateAudio()
          isPlaybackOpen = true
          showPlayer = true
          playback.openLocal(
            file,
            video: Video(
              bvid: "QA-local", title: "本地手势测试",
              cover: "", author: "", duration: 90, views: 0))
          if args.contains("--qa-special"),
            let data = try? Data(
              contentsOf: file.deletingLastPathComponent().appendingPathComponent("special.json")),
            data.count <= 2_000_000,
            let items = try? JSONDecoder().decode([Danmaku].self, from: data)
          {
            danmaku.items = items
          }
          qa = true
        }
      }
    #endif
    if !qa, let i = args.firstIndex(of: "--qa-video"), args.indices.contains(i + 1),
      let bvid = videoID(args[i + 1])
    {
      if args.contains("--qa-from-start") {
        let visit = MobileVideoVisit(bvid: bvid)
        visit.resume = PlaybackResume(position: 0, playing: true)
        beginVisit(visit)
      } else { open(bvid) }
      qa = true
    }
    if qa {
      qaTask = Task { [weak self] in
        for sample in 0..<90 {
          try? await Task.sleep(for: .seconds(1))
          guard let self, !Task.isCancelled else { return }
          await self.writeQA()
          #if DEBUG
            if args.contains("--qa-capture") && sample == 20 { MobileUIFixture.captureInterface() }
          #endif
        }
      }
    }
  }
  func open(_ bvid: String, initialCID: Int? = nil) {
    if showPlayer, let current = playerNavigation.current,
      current.bvid == bvid, initialCID == nil || initialCID == playback.selectedCID
    {
      // A repeated link returns to the existing video instead of adding a duplicate visit.
      if let index = playerNavigation.path.lastIndex(of: .video(current.id)) {
        playerNavigation.path = Array(playerNavigation.path.prefix(index + 1))
      } else {
        playerNavigation.path = []
      }
      return
    }
    beginVisit(MobileVideoVisit(bvid: bvid, cid: initialCID))
  }
  private func captureVisit() {
    guard let visit = playerNavigation.current else { return }
    visit.detail = playback.detail
    visit.cid = playback.selectedCID > 0 ? playback.selectedCID : visit.cid
    visit.resume =
      playback.pendingResume
      ?? PlaybackResume(position: playback.positionSeconds, playing: playback.isPlaying)
    visit.queue = queue
    playback.saveCurrentProgress()
  }
  private func beginVisit(_ visit: MobileVideoVisit) {
    captureVisit()
    let nested = showPlayer && playerNavigation.root != nil
    if !nested { playerNavigation.reset() }
    playerNavigation.visits[visit.id] = visit
    playerNavigation.active = visit.id
    if nested {
      playerNavigation.path.append(.video(visit.id))
    } else {
      playerNavigation.root = visit
    }
    loadVisit(visit)
    showPlayer = true
  }
  func restorePlayerRoute() {
    guard let visit = playerNavigation.visibleVideo else { return }
    if playerNavigation.active != visit.id {
      captureVisit()
      playerNavigation.active = visit.id
      queue = visit.queue
      loadVisit(visit)
    }
    playerNavigation.prune()
  }
  private func loadVisit(_ visit: MobileVideoVisit) {
    isPlaybackOpen = true
    comments = visit.comments
    extras.reset()
    danmaku.stop()
    actions.clear()
    activateAudio()
    #if DEBUG
      if MobileUIFixture.enabled {
        MobileUIFixture.openVideo(visit, store: self)
        return
      }
    #endif
    if let local = visit.local {
      playback.openLocal(
        URL(fileURLWithPath: local.path), video: local.video, cid: local.cid,
        sidecar: local.danmakuPath.map { URL(fileURLWithPath: $0) }, restoring: visit.resume)
    } else {
      playback.open(visit.bvid, api: api, initialCID: visit.cid, restoring: visit.resume) {
        [weak self] cid in
        self?.position(visit.bvid, cid: cid) ?? 0
      }
    }
  }
  private func activateAudio() {
    audioTask?.cancel()
    audioTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        try await MobileAudioSession.shared.activate()
      } catch {
        if !Task.isCancelled { self?.message = "音频会话：" + error.localizedDescription }
      }
    }
  }
  func position(_ bvid: String, cid: Int) -> Double {
    guard UserDefaults.standard.bool(forKey: "rememberPosition") else { return 0 }
    return history.first { $0.video.bvid == bvid && $0.accountID == owner }?.positions[String(cid)]
      ?? 0
  }
  var owner: String { api.cookies["DedeUserID"] ?? "guest" }
  func save(_ bvid: String, cid: Int, seconds: Double, final: Bool) {
    guard seconds.isFinite, seconds >= 0, let detail = playback.detail, detail.video.bvid == bvid
    else { return }
    var row =
      history.first { $0.video.bvid == bvid && $0.accountID == owner }
      ?? HistoryEntry(video: detail.video, positions: [:], date: .now, accountID: owner)
    row.positions[String(cid)] = seconds
    row.lastCID = cid
    row.date = .now
    history.removeAll { $0.id == row.id }
    history.insert(row, at: 0)
    history = Array(history.prefix(500))
    persist()
    historySync.record(
      api: api, aid: detail.aid, bvid: bvid, cid: cid, seconds: seconds, final: final)
  }
  func persist() {
    downloads.persist()
    if let data = try? JSONEncoder().encode(history) {
      UserDefaults.standard.set(data, forKey: "history")
    }
  }
  var currentQueue: [PlaybackQueueItem] {
    if let collection = playback.detail?.collection { return collection.items }
    if let detail = playback.detail, detail.pages.count > 1 {
      return detail.pages.map {
        PlaybackQueueItem(bvid: detail.video.bvid, cid: $0.id, title: $0.title)
      }
    }
    return queue
  }
  var hasNext: Bool {
    guard
      let index = currentQueue.firstIndex(where: {
        $0.bvid == playback.detail?.video.bvid && ($0.cid == nil || $0.cid == playback.selectedCID)
      })
    else { return false }
    return index + 1 < currentQueue.count
  }
  func next() {
    let items = currentQueue
    guard
      let index = items.firstIndex(where: {
        $0.bvid == playback.detail?.video.bvid && ($0.cid == nil || $0.cid == playback.selectedCID)
      }), items.indices.contains(index + 1)
    else { return }
    let item = items[index + 1]
    let present = showPlayer
    open(item.bvid, initialCID: item.cid)
    showPlayer = present
  }
  func openSaved(_ entry: SavedDownload) {
    beginVisit(MobileVideoVisit(bvid: entry.video.bvid, cid: entry.cid, local: entry))
  }
  func closePlayback() {
    mobilePiP.controller?.stopPictureInPicture()
    audioTask?.cancel()
    isPlaybackOpen = false
    playerNavigation.reset()
    playback.stop()
    comments.stop()
    extras.reset()
    danmaku.stop()
    showPlayer = false
  }
  func login() {
    showLogin = true
    refreshQR()
  }
  func refreshQR() {
    loginTask?.cancel()
    qrImage = nil
    loginExpired = false
    loginStatus = "正在获取二维码"
    loginTask = Task {
      do {
        let data = try await api.request("/x/passport-login/web/qrcode/generate")
        try Task.checkCancellation()
        guard let text = data["url"] as? String, let key = data["qrcode_key"] as? String else {
          throw BiliError(text: "无法读取二维码")
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        if let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) {
          qrImage = CIContext().createCGImage(image, from: image.extent)
        }
        loginStatus = "使用另一台设备上的哔哩哔哩 App 扫码"
        for sample in 0..<90 {
          try await Task.sleep(for: .seconds(2))
          try Task.checkCancellation()
          let result = try await api.request(
            "/x/passport-login/web/qrcode/poll", ["qrcode_key": key])
          try Task.checkCancellation()
          switch result["code"] as? Int {
          case 0:
            account = try await api.nav()
            showLogin = false
            actions.clear()
            return
          case 86090: loginStatus = "请在哔哩哔哩 App 中确认"
          case 86038:
            loginExpired = true
            loginStatus = "二维码已过期"
            return
          default: break
          }
        }
        loginExpired = true
        loginStatus = "二维码已过期"
      } catch {
        if !Task.isCancelled {
          loginStatus = error.localizedDescription
          loginExpired = true
        }
      }
    }
  }
  func closeLogin() {
    loginTask?.cancel()
    loginTask = nil
  }
  func logout() {
    closeLogin()
    closePlayback()
    api.logout()
    account = nil
    actions.clear()
    inbox.clear()
    accountHistory.reset()
    historySync.reset()
  }
  func verify(_ title: String = "官方验证") {
    webTarget = WebTarget(url: URL(string: "https://www.bilibili.com/")!, title: title)
  }
  private func writeQA() async {
    var state: [String: Any] = [
      "date": Date().ISO8601Format(), "loading": playback.loading,
      "renderedFrame": playback.renderedFrame,
      "playing": playback.isPlaying, "position": playback.positionSeconds,
      "duration": playback.durationSeconds,
      "quality": playback.selectedQuality, "format": playback.sourceFormat,
      "error": playback.error ?? "", "buffering": playback.buffering,
      "danmaku": danmaku.items.count, "ready": playback.player.currentItem?.status == .readyToPlay,
      "boosting": playback.isBoosting, "rate": playback.player.rate, "speed": playback.speed,
      "specialScripts": specialScripts, "specialLayers": specialLayers,
      "unsupportedScripts": unsupportedScripts,
    ]
    state["network"] = await playback.networkStats()
    state["transfers"] = await playback.transferStats()
    state["danmakuPerformance"] = danmakuPerformance
    state["orientation"] = orientationDiagnostics
    state["startupMS"] = playback.startupMilliseconds
    if qaTransferSamples.count < 12 {
      qaTransferSamples.append(["date": state["date"]!, "position": playback.positionSeconds, "transfers": state["transfers"]!, "network": state["network"]!])
    }
    state["startupSamples"] = qaTransferSamples
    state["bvid"] = playback.detail?.video.bvid ?? ""
    state["commentCount"] = comments.count
    state["commentCountLoaded"] = comments.hasLoadedCount
    state["metadataCommentCount"] = playback.detail?.counts.replies ?? -1
    let folder = AppPaths.support.appendingPathComponent("QA")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(
      withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: folder.appendingPathComponent("playback.json"), options: .atomic)
    }
  }
  func writeGestureQA(_ phase: String) {
    #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      guard args.contains("--qa-video") || args.contains("--qa-fixture") else { return }
      let folder = AppPaths.support.appendingPathComponent("QA")
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let state: [String: Any] = [
        "phase": phase, "boosting": playback.isBoosting,
        "rate": playback.player.rate, "speed": playback.speed,
        "temporarySpeed": playback.temporarySpeed,
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: folder.appendingPathComponent("boost-\(phase).json"), options: .atomic)
      }
    #endif
  }
  func writeFavoritesQA(_ editor: FavoriteEditor) {
    #if DEBUG
      guard ProcessInfo.processInfo.arguments.contains("--qa-favorites") else { return }
      let folder = AppPaths.support.appendingPathComponent("QA")
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let state: [String: Any] = [
        "loaded": editor.loaded, "folders": editor.folders.count,
        "selected": editor.selected.count, "error": editor.error ?? "",
      ]
      if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]) {
        try? data.write(to: folder.appendingPathComponent("favorites.json"), options: .atomic)
      }
    #endif
  }
}

enum AppPaths {
  static var support: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BiliGlass")
  }
  static var cache: URL { support.appendingPathComponent("MediaCache") }
  static var transfers: URL { support.appendingPathComponent("Transfers") }
}

@main struct BilibiliMobileApp: App {
  @State private var store = Store()
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      MobileRoot(store: store).tint(biliPink)
        .task { await store.start() }
        .onOpenURL { url in
          if let bvid = videoID(url.absoluteString) {
            store.open(bvid)
          } else if url.scheme == "bilibilinext",
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(
              where: { $0.name == "bvid" })?.value, let bvid = videoID(raw)
          {
            store.open(bvid)
          }
        }
        .onChange(of: phase) { _, value in
          if value != .active {
            store.playback.endTemporarySpeed()
            store.playback.saveCurrentProgress()
            store.persist()
          }
        }
    }
  }
}
