import Foundation
import SwiftUI

struct VideoCounts: Sendable {
  var likes: Int
  var coins: Int
  var favorites: Int
  var shares: Int
  init(_ data: [String: Any] = [:]) {
    likes = max(0, data["like"] as? Int ?? 0)
    coins = max(0, data["coin"] as? Int ?? 0)
    favorites = max(0, data["favorite"] as? Int ?? 0)
    shares = max(0, data["share"] as? Int ?? 0)
  }
}
struct VideoRelation: Equatable, Sendable {
  var liked: Bool
  var coins: Int
  var favorited: Bool
}
struct CoinAvailability {
  let limit: Int
  let coins: Int?
  let balance: Double?
  var available: Int {
    guard let coins, let balance, balance.isFinite else { return 0 }
    return max(0, min(limit - coins, Int(max(0, min(2, balance)))))
  }
  func reason(for amount: Int) -> String? {
    if limit == 1 && amount == 2 { return "转载视频最多投 1 枚硬币" }
    guard let coins else { return "未能读取已投数量，请刷新状态" }
    if coins >= limit { return "本视频已投满" }
    if amount > limit - coins { return "已投 \(coins) 枚，本次最多投 \(limit - coins) 枚" }
    guard let balance, balance.isFinite else { return "未能读取硬币余额，请刷新状态" }
    if balance < Double(amount) { return "余额不足 \(amount) 枚硬币" }
    return nil
  }
}
struct FavoriteChanges: Equatable {
  let added: [Int]
  let removed: [Int]
  init(original: Set<Int>, selected: Set<Int>) {
    added = selected.subtracting(original).sorted()
    removed = original.subtracting(selected).sorted()
  }
  var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}
enum VideoShareLink {
  static func make(bvid: String, page: Int, seconds: Double?) -> URL {
    var url = URLComponents(string: "https://www.bilibili.com/video/")!
    url.path += bvid + "/"
    var query: [URLQueryItem] = []
    if page > 1 { query.append(URLQueryItem(name: "p", value: String(page))) }
    if let seconds, seconds.isFinite, seconds > 0 {
      query.append(URLQueryItem(name: "t", value: String(Int(min(604800, seconds)))))
    }
    if !query.isEmpty { url.queryItems = query }
    return url.url!
  }
}

extension API {
  func videoRelation(_ aid: Int, bvid: String? = nil) async throws -> VideoRelation {
    var query = ["aid": String(aid)]
    if let bvid { query["bvid"] = bvid }
    let requestQuery = query
    @Sendable func read(_ path: String, title: String) async throws -> [String: Any] {
      do { return try await request(path, requestQuery) }
      catch is CancellationError { throw CancellationError() }
      catch { throw BiliError(text: title + "读取失败：" + error.localizedDescription, code: (error as? BiliError)?.code) }
    }
    async let like = read("/x/web-interface/archive/has/like", title: "点赞状态")
    async let coins = read("/x/web-interface/archive/coins", title: "已投币数量")
    async let favorite = read("/x/v2/fav/video/favoured", title: "收藏状态")
    let (l, c, f) = try await (like, coins, favorite)
    guard let liked = l["value"] as? Int, let count = c["multiply"] as? Int,
      let favored = f["favoured"] as? Bool else { throw BiliError(text: "互动状态返回不完整，请刷新") }
    return VideoRelation(liked: liked != 0, coins: max(0, count), favorited: favored)
  }
  /// Obtain the site's own browser identifier instead of manufacturing an identity for writes.
  func prepareVideoInteraction() async throws {
    guard signedIn else { throw BiliError(text: "请先登录") }
    guard cookies["buvid3"] == nil else { return }
    let sessionID = authenticationGeneration
    let result = try await request("/x/frontend/finger/spi")
    try Task.checkCancellation()
    guard sessionID == authenticationGeneration else { throw CancellationError() }
    guard let id = result["b_3"] as? String, !id.isEmpty else { throw BiliError(text: "无法准备互动请求，请稍后重试") }
    cookies["buvid3"] = id
    if let id4 = result["b_4"] as? String { cookies["buvid4"] = id4 }
  }
  func setVideoLike(aid: Int, liked: Bool) async throws {
    try await prepareVideoInteraction()
    _ = try await post("/x/web-interface/archive/like", ["aid": String(aid), "like": liked ? "1" : "2"])
  }
  func addVideoCoins(aid: Int, amount: Int, alsoLike: Bool) async throws -> Bool {
    guard (1...2).contains(amount) else { throw BiliError(text: "请选择 1 或 2 枚硬币") }
    try await prepareVideoInteraction()
    let result = try await post("/x/web-interface/coin/add", ["aid": String(aid), "multiply": String(amount), "select_like": alsoLike ? "1" : "0"])
    return result["like"] as? Bool ?? false
  }
  func changeVideoFavorites(aid: Int, changes: FavoriteChanges) async throws {
    guard !changes.isEmpty else { return }
    try await prepareVideoInteraction()
    _ = try await post("/x/v3/fav/resource/deal", ["rid": String(aid), "type": "2",
      "add_media_ids": changes.added.map(String.init).joined(separator: ","),
      "del_media_ids": changes.removed.map(String.init).joined(separator: ",")])
  }
  func createFavoriteFolder(title: String, isPrivate: Bool) async throws -> FavoriteFolder {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 20 else { throw BiliError(text: "收藏夹名称需要 1–20 个字") }
    try await prepareVideoInteraction()
    let result = try await post("/x/v3/fav/folder/add", ["title": name, "privacy": isPrivate ? "1" : "0"])
    guard let id = result["id"] as? Int, id > 0 else { throw BiliError(text: "收藏夹已提交，请刷新列表确认") }
    return FavoriteFolder(id: id, title: result["title"] as? String ?? name, count: 0, isPrivate: isPrivate)
  }
}

@MainActor @Observable final class VideoActionsModel {
  private(set) var aid = 0
  private(set) var accountID: Int?
  private(set) var counts = VideoCounts()
  private(set) var relation: VideoRelation?
  private(set) var loading = false
  private(set) var operation: String?
  var error: String?
  var notice: String?
  private(set) var needsVerification = false
  private var revision = UUID()
  func clear() {
    revision = UUID(); aid = 0; accountID = nil; counts = VideoCounts()
    relation = nil; loading = false; operation = nil; error = nil; notice = nil; needsVerification = false
  }
  func load(detail: Detail, accountID: Int?, api: API) async {
    guard operation == nil else { return }
    if aid != detail.aid || self.accountID != accountID {
      clear(); aid = detail.aid; self.accountID = accountID; counts = detail.counts
    }
    revision = UUID()
    let token = revision, session = api.authenticationGeneration
    error = nil; needsVerification = false
    guard accountID != nil, api.signedIn else { relation = nil; loading = false; return }
    loading = true
    defer { if token == revision { loading = false } }
    do {
      let result = try await api.videoRelation(detail.aid, bvid: detail.video.bvid)
      guard !Task.isCancelled, token == revision, session == api.authenticationGeneration else { return }
      relation = result; loading = false
    } catch {
      guard token == revision, session == api.authenticationGeneration else { return }
      loading = false
      if !(error is CancellationError) { failure(error); relation = nil }
    }
  }
  func toggleLike(api: API) async {
    guard let before = relation, operation == nil, !loading, aid > 0 else { return }
    let target = aid, token = revision, session = api.authenticationGeneration
    operation = "like"; error = nil; notice = nil; needsVerification = false
    defer { if token == revision { operation = nil } }
    do {
      try await api.setVideoLike(aid: target, liked: !before.liked)
      guard token == revision, session == api.authenticationGeneration else { return }
      relation?.liked = !before.liked
      counts.likes = max(0, counts.likes + (before.liked ? -1 : 1))
      notice = before.liked ? "已取消点赞" : "已点赞"
    } catch {
      guard token == revision, session == api.authenticationGeneration else { return }
      failure(error)
      if !(error is BiliError) { relation = nil; self.error = "结果未确认，请刷新状态后再操作" }
    }
    if token == revision { operation = nil }
  }
  func sendCoins(amount: Int, limit: Int, balance: Double, alsoLike: Bool, api: API) async -> Bool {
    guard let before = relation, operation == nil, !loading, aid > 0,
      amount > 0, amount <= min(2, limit) - before.coins, balance.isFinite, balance >= Double(amount)
    else { error = "可投数量或硬币余额不足，请刷新后重试"; return false }
    let target = aid, token = revision, session = api.authenticationGeneration
    operation = "coin"; error = nil; notice = nil; needsVerification = false
    defer { if token == revision { operation = nil } }
    do {
      let liked = try await api.addVideoCoins(aid: target, amount: amount, alsoLike: alsoLike)
      guard token == revision, session == api.authenticationGeneration else { return false }
      relation?.coins += amount; counts.coins += amount
      if liked && !before.liked { relation?.liked = true; counts.likes += 1 }
      notice = "已投 \(amount) 枚硬币"; operation = nil
      return true
    } catch {
      guard token == revision, session == api.authenticationGeneration else { return false }
      failure(error)
      // A timeout can happen after the server has accepted a coin. Never retry a write automatically.
      relation = nil; operation = nil
      if !(error is BiliError) { self.error = "投币结果未确认，请刷新状态后再操作" }
      return false
    }
  }
  func favoritesSaved(aid: Int, isFavorite: Bool) {
    guard self.aid == aid else { return }
    if let before = relation, before.favorited != isFavorite {
      counts.favorites = max(0, counts.favorites + (isFavorite ? 1 : -1))
    }
    relation?.favorited = isFavorite
    notice = isFavorite ? "收藏已更新" : "已取消收藏"
  }
  private func failure(_ error: Error) {
    self.error = error.localizedDescription
    needsVerification = (error as? BiliError)?.requiresVerification ?? false
  }
}

@MainActor @Observable final class FavoriteEditor {
  let aid: Int
  let mid: Int
  var folders: [FavoriteFolder] = []
  var selected: Set<Int> = []
  private(set) var original: Set<Int> = []
  private(set) var loading = false
  private(set) var saving = false
  private(set) var loaded = false
  var error: String?
  var needsVerification = false
  private var revision = UUID()
  init(aid: Int, mid: Int) { self.aid = aid; self.mid = mid }
  var changes: FavoriteChanges { FavoriteChanges(original: original, selected: selected) }
  func load(api: API) async {
    guard !saving else { return }
    revision = UUID(); let token = revision, session = api.authenticationGeneration
    loading = true; error = nil; needsVerification = false
    defer { if token == revision { loading = false } }
    do {
      let result = try await api.favoriteFolders(mid, aid: aid)
      guard !Task.isCancelled, token == revision, session == api.authenticationGeneration else { return }
      folders = result; original = Set(result.filter(\.containsVideo).map(\.id)); selected = original
      loaded = true; loading = false
    } catch {
      guard token == revision, session == api.authenticationGeneration else { return }
      loading = false; loaded = false
      if !(error is CancellationError) { failure(error) }
    }
  }
  func create(title: String, isPrivate: Bool, api: API) async -> Bool {
    guard loaded, !saving, !loading else { return false }
    saving = true; error = nil
    let session = api.authenticationGeneration
    defer { saving = false }
    do {
      let folder = try await api.createFavoriteFolder(title: title, isPrivate: isPrivate)
      guard session == api.authenticationGeneration else { return false }
      folders.append(folder); selected.insert(folder.id); return true
    } catch { failure(error); loaded = false; return false }
  }
  func save(api: API) async -> Bool {
    guard loaded, !loading, !saving else { return false }
    let selection = selected.intersection(Set(folders.map(\.id)))
    let delta = FavoriteChanges(original: original, selected: selection)
    if delta.isEmpty { return true }
    saving = true; error = nil
    let session = api.authenticationGeneration
    defer { saving = false }
    do {
      try await api.changeVideoFavorites(aid: aid, changes: delta)
      guard session == api.authenticationGeneration else { return false }
      folders = folders.map { folder in
        FavoriteFolder(id: folder.id, title: folder.title,
          count: max(0, folder.count + (delta.added.contains(folder.id) ? 1 : delta.removed.contains(folder.id) ? -1 : 0)),
          containsVideo: selection.contains(folder.id), isPrivate: folder.isPrivate)
      }
      original = selection; selected = selection; return true
    } catch { failure(error); loaded = false; return false }
  }
  private func failure(_ error: Error) {
    self.error = error.localizedDescription; needsVerification = (error as? BiliError)?.requiresVerification ?? false
  }
}
