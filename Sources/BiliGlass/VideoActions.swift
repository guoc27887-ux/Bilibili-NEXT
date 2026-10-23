import Foundation
import SwiftUI

/// Keep the server's verification request in memory, scoped to the exact write.
/// A completed challenge permits one explicit resubmission, never an automatic spend.
struct InteractionChallenge: Identifiable, Sendable {
  let id = UUID()
  let code: Int
  let payload: Data
  let path: String
  let body: [String: String]
  let authentication: UUID

  static func parse(_ root: [String: Any], response: HTTPURLResponse, path: String,
                    body: [String: String], authentication: UUID) -> Self? {
    guard let code = root["code"] as? Int, [-401, -352].contains(code) else { return nil }
    let data = root["data"] as? [String: Any] ?? [:]
    let options: [String: Any]
    if code == -401 {
      guard let gaia = data["ga_data"] as? [String: Any], !gaia.isEmpty else { return nil }
      options = gaia
    } else {
      let voucher = response.value(forHTTPHeaderField: "x-bili-gaia-vvoucher")
      let risk = voucher.map { ["v_voucher": $0] } ?? data
      guard !risk.isEmpty else { return nil }
      options = ["riskParams": risk]
    }
    guard JSONSerialization.isValidJSONObject(options),
      let payload = try? JSONSerialization.data(withJSONObject: options), payload.count <= 65_536 else { return nil }
    return Self(code: code, payload: payload, path: path, body: body, authentication: authentication)
  }
}
struct InteractionVerificationGrant {
  let challenge: InteractionChallenge
  let token: String
  let expires: Date
}

extension API {
  @discardableResult
  func acceptVerification(_ token: String, for challenge: InteractionChallenge, now: Date = Date()) -> Bool {
    guard challenge.authentication == authenticationGeneration,
      challenge.body["csrf"] == cookies["bili_jct"], signedIn,
      !token.isEmpty, token.utf8.count <= 16_384 else { return false }
    interactionVerification = InteractionVerificationGrant(challenge: challenge, token: token,
      expires: now.addingTimeInterval(120))
    return true
  }
  func consumeVerification(path: String, body: [String: String], now: Date = Date()) -> InteractionVerificationGrant? {
    guard let grant = interactionVerification else { return nil }
    guard grant.expires > now, grant.challenge.authentication == authenticationGeneration else {
      interactionVerification = nil; return nil
    }
    guard grant.challenge.path == path, grant.challenge.body == body else { return nil }
    interactionVerification = nil
    return grant
  }
  static let interactionCookieNames: Set<String> = [
    "buvid3", "buvid4", "b_nut", "_uuid", "b_lsid", "buvid_fp", "bili_ticket", "bili_ticket_expires",
  ]
}

struct VideoCounts: Sendable {
  var likes: Int
  var coins: Int
  var favorites: Int
  var shares: Int
  var replies: Int?
  init(_ data: [String: Any] = [:]) {
    likes = max(0, data["like"] as? Int ?? 0)
    coins = max(0, data["coin"] as? Int ?? 0)
    favorites = max(0, data["favorite"] as? Int ?? 0)
    shares = max(0, data["share"] as? Int ?? 0)
    replies = (data["reply"] as? Int).map { max(0, $0) }
  }
}
struct VideoRelation: Equatable, Sendable {
  var liked: Bool
  var coins: Int
  var favorited: Bool
}
struct TripleResult: Sendable {
  let like: Bool
  let coin: Bool
  let favorite: Bool
  let count: Int
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
    let data = try await request("/x/web-interface/archive/relation", query)
    guard let liked = data["like"] as? Bool, let coins = data["coin"] as? Int,
      let favorite = data["favorite"] as? Bool, coins >= 0 else {
      throw BiliError(text: "互动状态返回不完整，请刷新")
    }
    return VideoRelation(liked: liked, coins: coins, favorited: favorite)
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
  func setVideoLike(aid: Int, bvid: String? = nil, liked: Bool) async throws {
    try await prepareVideoInteraction()
    _ = try await post("/x/web-interface/archive/like", ["aid": String(aid), "like": liked ? "1" : "2"], videoBVID: bvid)
  }
  func addVideoCoins(aid: Int, bvid: String? = nil, amount: Int, alsoLike: Bool) async throws -> Bool {
    guard (1...2).contains(amount) else { throw BiliError(text: "请选择 1 或 2 枚硬币") }
    if let credential = appCoinAuthorization, credential.accountID == Int(cookies["DedeUserID"] ?? "") {
      return try await addAppCoins(aid: aid, amount: amount, alsoLike: alsoLike, credential: credential)
    }
    try await prepareVideoInteraction()
    let result = try await post("/x/web-interface/coin/add", ["aid": String(aid), "multiply": String(amount), "select_like": alsoLike ? "1" : "0", "cross_domain": "true"], videoBVID: bvid)
    return result["like"] as? Bool ?? false
  }
  func tripleVideo(aid: Int, bvid: String) async throws -> TripleResult {
    try await prepareVideoInteraction()
    let data = try await post("/x/web-interface/archive/like/triple", ["aid": String(aid)], videoBVID: bvid)
    guard let like = data["like"] as? Bool, let coin = data["coin"] as? Bool,
      let fav = data["fav"] as? Bool, let count = data["multiply"] as? Int,
      (0...2).contains(count) else { throw BiliError(text: "三连结果不完整，请刷新状态后查看") }
    return TripleResult(like: like, coin: coin, favorite: fav, count: count)
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
  private var bvid = ""
  private(set) var accountID: Int?
  private(set) var counts = VideoCounts()
  private(set) var relation: VideoRelation?
  private var favoriteOverride: Bool?
  var isFavorited: Bool { favoriteOverride ?? relation?.favorited ?? false }
  private(set) var loading = false
  private(set) var operation: String?
  var error: String?
  var notice: String?
  private(set) var needsVerification = false
  private(set) var challenge: InteractionChallenge?
  private var revision = UUID()
  func clear() {
    revision = UUID(); aid = 0; accountID = nil; counts = VideoCounts()
    relation = nil; favoriteOverride = nil; loading = false; operation = nil; error = nil; notice = nil; needsVerification = false; challenge = nil
  }
  func load(detail: Detail, accountID: Int?, api: API) async {
    guard operation == nil else { return }
    if aid != detail.aid || self.accountID != accountID {
      clear(); aid = detail.aid; bvid = detail.video.bvid; self.accountID = accountID; counts = detail.counts
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
      relation = result; favoriteOverride = result.favorited; loading = false
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
      try await api.setVideoLike(aid: target, bvid: bvid, liked: !before.liked)
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
      let liked = try await api.addVideoCoins(aid: target, bvid: bvid, amount: amount, alsoLike: alsoLike)
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
  func sendTriple(api: API) async -> Bool {
    guard let before = relation, operation == nil, !loading, aid > 0 else { return false }
    let token = revision, session = api.authenticationGeneration
    operation = "triple"; error = nil; notice = nil; needsVerification = false
    defer { if token == revision { operation = nil } }
    do {
      let result = try await api.tripleVideo(aid: aid, bvid: bvid)
      guard token == revision, session == api.authenticationGeneration else { return false }
      if result.like && !before.liked { relation?.liked = true; counts.likes += 1 }
      if result.coin { relation?.coins += result.count; counts.coins += result.count }
      if result.favorite && !before.favorited { relation?.favorited = true; favoriteOverride = true; counts.favorites += 1 }
      let complete = relation?.liked == true && (relation?.coins ?? 0) > 0 && relation?.favorited == true
      notice = complete ? "已三连" : "已完成部分操作，请查看互动状态"
      if !complete { error = "三连未全部完成；已成功的操作已保留，请刷新状态后查看" }
      return complete
    } catch {
      guard token == revision, session == api.authenticationGeneration else { return false }
      failure(error); relation = nil
      if !(error is BiliError) { self.error = "三连结果未确认，请刷新状态后查看" }
      return false
    }
  }
  func favoritesSaved(aid: Int, isFavorite: Bool, wasFavorite: Bool? = nil) {
    guard self.aid == aid else { return }
    revision = UUID(); loading = false
    if let before = wasFavorite ?? relation?.favorited, before != isFavorite {
      counts.favorites = max(0, counts.favorites + (isFavorite ? 1 : -1))
    }
    favoriteOverride = isFavorite
    relation?.favorited = isFavorite
    notice = isFavorite ? "收藏已更新" : "已取消收藏"
  }
  private func failure(_ error: Error) {
    challenge = (error as? BiliError)?.challenge
    self.error = challenge != nil ? "请完成官方验证后，再确认提交"
      : (error as? BiliError)?.code == -403
      ? "哔哩哔哩拒绝了互动请求（-403），请完成官方验证后刷新状态"
      : error.localizedDescription
    needsVerification = (error as? BiliError)?.requiresVerification ?? false
  }
  func verificationCompleted() {
    challenge = nil; needsVerification = false; error = nil
    notice = "验证已完成，请再次确认操作"
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
