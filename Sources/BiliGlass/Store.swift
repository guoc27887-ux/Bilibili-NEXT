import CoreImage.CIFilterBuiltins
import SwiftUI

struct HistoryEntry: Codable, Identifiable {
  var id: String { video.bvid }
  var video: Video
  var positions: [String: Double]
  var date: Date
}
enum Destination: String, CaseIterable, Identifiable {
  case recommend = "推荐"
  case popular = "热门"
  case dynamic = "关注动态"
  case history = "观看记录"
  case favorites = "收藏"
  case later = "稍后再看"
  case downloads = "下载"
  case profile = "我的主页"
  case messages = "消息"
  case web = "更多"
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .recommend: "house"
    case .popular: "flame"
    case .dynamic: "person.2"
    case .history: "clock"
    case .favorites: "star"
    case .later: "text.badge.plus"
    case .downloads: "arrow.down.circle"
    case .profile: "person.crop.circle"
    case .messages: "bubble.left.and.bubble.right"
    case .web: "ellipsis.circle"
    }
  }
}
struct ProfileTarget: Identifiable { let id: Int }
private struct FeedSnapshot: Codable {
  let items: [Video]
  let page: Int
  let hasMore: Bool
  let date: Date
  let owner: String
}
@MainActor @Observable final class Store {
  let api = API(loadCredentials: false)
  let playback = Playback()
  let fullscreen = FullscreenPlayerController()
  let downloads = Downloads()
  let comments = Comments()
  let videoActions = VideoActionsModel()
  let inbox = InboxModel()
  let accountHistory = AccountHistory()
  var danmaku = DanmakuController()
  var navigationRevision = 0
  var profileTarget: ProfileTarget?
  var webTarget: WebTarget?
  var imageGallery: ImageGalleryTarget?
  var folders: [FavoriteFolder] = []
  var selectedFolder = 0
  var interactionMessage: String?
  var destination: Destination = .recommend
  var searchFocus = 0
  var playerFocus = 0
  var videos: [Video] = []
  var history: [HistoryEntry] = []
  var query = ""
  var activeQuery = ""
  var page = 1
  var hasMore = true
  var busy = false
  var feedMilliseconds = 0
  var error: String?
  var restoring = true
  var account: Account?
  var showLogin = false
  var showPlayer = false
  var qrImage: NSImage?
  var loginStatus = ""
  var loginExpired = false
  private var feedTask: Task<Void, Never>?
  private var loginTask: Task<Void, Never>?
  private var feedID = UUID()
  private var loadingFeedKey: String?
  private var feedSnapshots: [Destination: FeedSnapshot] = [:]
  private var feedKey: String { destination.rawValue + "|" + activeQuery + "|\(selectedFolder)" }
  private var feedOwner: String { api.cookies["DedeUserID"] ?? "guest" }
  init() {
    if let data = UserDefaults.standard.data(forKey: "history") {
      history = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }
    playback.onProgress = { [weak self] bvid, cid, seconds in
      self?.saveProgress(bvid, cid: cid, seconds: seconds)
    }
  }
  func start() async {
    await api.restoreCredentials()
    if let data = UserDefaults.standard.data(forKey: "homeFeedSnapshot"),
      let cached = try? JSONDecoder().decode(FeedSnapshot.self, from: data),
      cached.owner == feedOwner, Date().timeIntervalSince(cached.date) < 86_400 {
      videos = cached.items
    }
    // Account validation and the signed feed share one navigation request.
    async let restoredAccount = api.nav()
    reload()
    account = try? await restoredAccount
    restoring = false
  }
  func reload() {
    if destination == .history && !showPlayer {
      if UserDefaults.standard.string(forKey: "historySource") != "local" {
        Task { await accountHistory.load(api: api, refresh: true) }
      }
      return
    }
    guard !busy || loadingFeedKey != feedKey else { return }
    feedTask?.cancel()
    feedID = UUID()
    let token = feedID
    page = 1
    hasMore = true
    error = nil
    busy = true
    loadingFeedKey = feedKey
    let began = ContinuousClock.now
    feedTask = Task {
      do {
        let items =
          try await (activeQuery.isEmpty ? feed(page: 1) : api.search(activeQuery, page: 1))
        try Task.checkCancellation()
        guard token == feedID else { return }
        videos = Video.deduplicated(items)
        hasMore =
          destination == .dynamic
          ? api.dynamicHasMore : destination != .later && !items.isEmpty
        busy = false
        loadingFeedKey = nil
        let elapsed = began.duration(to: .now).components
        feedMilliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        rememberFeed()
      } catch {
        guard token == feedID, !Task.isCancelled else { return }
        busy = false
        loadingFeedKey = nil
        self.error = error.localizedDescription
      }
    }
  }
  func search() {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if let bv = videoID(term) {
      open(bv)
      return
    }
    videoActions.clear()
    comments.stop()
    danmaku.stop()
    navigationRevision += 1
    profileTarget = nil
    destination = .popular
    showPlayer = false
    playback.stop()
    activeQuery = term
    videos = []
    reload()
  }
  func clearSearch() {
    query = ""
    guard !showPlayer else { return }
    activeQuery = ""
    reload()
  }
  func openSaved(_ entry: SavedDownload) {
    navigationRevision += 1
    profileTarget = nil
    videoActions.clear(); comments.stop(); danmaku.stop()
    showPlayer = true
    playerFocus += 1
    playback.focusPlayer()
    playback.openLocal(URL(fileURLWithPath: entry.path), video: entry.video, cid: entry.cid,
      sidecar: entry.danmakuPath.map { URL(fileURLWithPath: $0) })
    let token = playback.generation
    // Cached playback starts immediately; optional online metadata enables comments
    // and interactions without replacing the local media or requiring a connection.
    Task {
      guard let detail = try? await api.detail(entry.video.bvid), playback.generation == token,
        playback.isOffline else { return }
      playback.detail = detail
    }
  }
  func more() {
    guard !busy, hasMore else { return }
    busy = true
    loadingFeedKey = feedKey
    let token = feedID
    let next = page + 1
    error = nil
    feedTask = Task {
      do {
        let items =
          try await (activeQuery.isEmpty ? feed(page: next) : api.search(activeQuery, page: next))
        try Task.checkCancellation()
        guard token == feedID else { return }
        let ids = Set(videos.map(\.id))
        videos += Video.deduplicated(items, excluding: ids)
        page = next
        hasMore =
          destination == .dynamic
          ? api.dynamicHasMore : !items.isEmpty && videos.count > ids.count
        busy = false
        loadingFeedKey = nil
        rememberFeed()
      } catch {
        guard token == feedID, !Task.isCancelled else { return }
        busy = false
        loadingFeedKey = nil
        self.error = error.localizedDescription
      }
    }
  }
  func showProfile(_ mid: Int) {
    navigationRevision += 1
    profileTarget = ProfileTarget(id: mid)
  }
  func open(_ bvid: String) {
    videoActions.clear()
    navigationRevision += 1
    profileTarget = nil
    comments.stop()
    danmaku.stop()
    showPlayer = true
    playerFocus += 1
    playback.focusPlayer()
    playback.open(bvid, api: api) { [weak self] cid in self?.position(bvid, cid: cid) ?? 0 }
  }
  func openHistory(_ entry: AccountHistoryEntry) {
    videoActions.clear(); navigationRevision += 1; profileTarget = nil
    comments.stop(); danmaku.stop(); showPlayer = true; playerFocus += 1
    playback.focusPlayer()
    playback.open(entry.video.bvid, api: api, initialCID: entry.cid) { cid in
      cid == entry.cid ? Double(max(0, entry.progress)) : 0
    }
  }
  func position(_ bvid: String, cid: Int) -> Double {
    history.first { $0.video.bvid == bvid }?.positions["\(cid)"] ?? 0
  }
  func saveProgress(_ bvid: String, cid: Int, seconds: Double) {
    guard let video = playback.detail?.video, video.bvid == bvid, seconds > 0 else { return }
    var entry =
      history.first { $0.video.bvid == bvid }
      ?? HistoryEntry(video: video, positions: [:], date: Date())
    entry.positions["\(cid)"] = seconds
    entry.date = Date()
    history.removeAll { $0.video.bvid == bvid }
    history.insert(entry, at: 0)
    history = Array(history.prefix(200))
    persistHistory()
  }
  func persistHistory() {
    if let d = try? JSONEncoder().encode(history) {
      UserDefaults.standard.set(d, forKey: "history")
    }
  }
  func navigate(_ dest: Destination) {
    feedTask?.cancel(); feedID = UUID(); busy = false; loadingFeedKey = nil
    videoActions.clear()
    navigationRevision += 1
    profileTarget = nil
    destination = dest
    activeQuery = ""
    query = ""
    videos = []
    showPlayer = false
    playback.stop()
    comments.stop()
    danmaku.stop()
    if let cached = feedSnapshots[dest], cached.owner == feedOwner,
      Date().timeIntervalSince(cached.date) < 300 {
      videos = cached.items; page = cached.page; hasMore = cached.hasMore; error = nil
    } else if [.recommend, .popular, .dynamic, .favorites, .later].contains(dest) { reload() }
  }
  private func rememberFeed() {
    guard activeQuery.isEmpty, [.recommend, .popular].contains(destination), !videos.isEmpty, !busy else { return }
    let snapshot = FeedSnapshot(items: videos, page: page, hasMore: hasMore, date: Date(), owner: feedOwner)
    feedSnapshots[destination] = snapshot
    if destination == .recommend, page == 1, let data = try? JSONEncoder().encode(snapshot) {
      UserDefaults.standard.set(data, forKey: "homeFeedSnapshot")
    }
  }
  func feed(page: Int) async throws -> [Video] {
    switch destination {
    case .recommend: return try await api.recommendations(page: page)
    case .popular: return try await api.popular(page: page)
    case .dynamic:
      guard account != nil else { throw BiliError(text: "登录后查看关注动态") }
      return try await api.followedVideos(page: page)
    case .favorites:
      guard let account else { throw BiliError(text: "登录后查看收藏") }
      if folders.isEmpty { folders = try await api.favoriteFolders(account.mid) }
      if selectedFolder == 0 { selectedFolder = folders.first?.id ?? 0 }
      guard selectedFolder > 0 else { return [] }
      return try await api.favorites(selectedFolder, page: page)
    case .later:
      guard account != nil else { throw BiliError(text: "登录后查看稍后再看") }
      return page == 1 ? try await api.later() : []
    default: return []
    }
  }
  func addLater(_ aid: Int) async {
    do {
      _ = try await api.post("/x/v2/history/toview/add", ["aid": "\(aid)"])
      interactionMessage = "已加入稍后再看"
    } catch { interactionMessage = error.localizedDescription }
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
        let d = try await api.request("/x/passport-login/web/qrcode/generate")
        try Task.checkCancellation()
        guard let url = d["url"] as? String, let key = d["qrcode_key"] as? String else {
          throw BiliError(text: "二维码获取失败")
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        guard let ci = filter.outputImage,
          let cg = CIContext().createCGImage(
            ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            from: ci.extent.applying(CGAffineTransform(scaleX: 8, y: 8)))
        else { throw BiliError(text: "二维码生成失败") }
        qrImage = NSImage(cgImage: cg, size: NSSize(width: 208, height: 208))
        loginStatus = "使用哔哩哔哩 App 扫码"
        for _ in 0..<90 {
          try await Task.sleep(for: .seconds(2))
          try Task.checkCancellation()
          let p = try await api.request("/x/passport-login/web/qrcode/poll", ["qrcode_key": key])
          try Task.checkCancellation()
          switch p["code"] as? Int {
          case 0:
            videoActions.clear()
            account = try await api.nav()
            loginStatus = "已登录"
            showLogin = false
            if !showPlayer { reload() }
            return
          case 86090: loginStatus = "请在手机上确认"
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
    qrImage = nil
  }
  func logout() {
    feedTask?.cancel(); feedID = UUID(); busy = false; loadingFeedKey = nil
    feedSnapshots.removeAll()
    UserDefaults.standard.removeObject(forKey: "homeFeedSnapshot")
    videoActions.clear()
    inbox.clear()
    accountHistory.reset()
    playback.stop()
    showPlayer = false
    navigationRevision += 1
    profileTarget = nil
    api.logout()
    destination = .recommend
    activeQuery = ""; query = ""
    account = nil
    videos = []
    folders = []
    selectedFolder = 0
    comments.stop()
    danmaku.stop()
    reload()
  }
}
