import Foundation
import SwiftUI

struct MessageUnreadCounts: Equatable {
  var replies = 0
  var mentions = 0
  var likes = 0
  var privateMessages = 0
  var total: Int { replies + mentions + likes + privateMessages }
  subscript(kind: Int) -> Int {
    switch kind { case 0: privateMessages; case 1: replies; case 2: mentions; case 3: likes; default: 0 }
  }
  static func number(_ raw: Any?) -> Int? {
    guard let value = (raw as? NSNumber)?.intValue ?? Int(raw as? String ?? "") else { return nil }
    return max(0, min(value, 1_000_000))
  }
  mutating func applyFeed(_ data: [String: Any]) -> Bool {
    // recv_reply is a combined counter, not an additional reply category.
    guard let reply = Self.number(data["reply"]), let at = Self.number(data["at"]),
      let like = Self.number(data["like"] ?? data["recv_like"]) else { return false }
    replies = reply; mentions = at; likes = like
    return true
  }
  mutating func applyPrivate(_ data: [String: Any]) -> Bool {
    guard let follow = Self.number(data["follow_unread"]),
      let unfollow = Self.number(data["unfollow_unread"]) else { return false }
    // Push, business and dustbin fields are separate/overlapping totals.
    privateMessages = follow + unfollow
    return true
  }
}

@MainActor @Observable final class MessageUnreadModel {
  private(set) var counts = MessageUnreadCounts()
  private(set) var error: String?
  private var authentication: UUID?
  private var requestID = UUID()
  func reset() {
    requestID = UUID(); authentication = nil; counts = .init(); error = nil
  }
  func refresh(api: API) async {
    guard api.signedIn else { reset(); return }
    let auth = api.authenticationGeneration
    if authentication != auth { reset(); authentication = auth }
    let token = UUID(); requestID = token
    var failures = false
    do {
      let data = try await api.request("/x/msgfeed/unread", ["build": "0", "mobi_app": "web"])
      guard token == requestID, auth == api.authenticationGeneration, !Task.isCancelled else { return }
      failures = !counts.applyFeed(data)
    } catch {
      guard token == requestID, auth == api.authenticationGeneration, !Task.isCancelled else { return }
      failures = true
    }
    do {
      let data = try await api.messageRequest("/session_svr/v1/session_svr/single_unread",
        ["build": "0", "mobi_app": "web", "unread_type": "0"])
      guard token == requestID, auth == api.authenticationGeneration, !Task.isCancelled else { return }
      if !counts.applyPrivate(data) { failures = true }
    } catch {
      guard token == requestID, auth == api.authenticationGeneration, !Task.isCancelled else { return }
      failures = true
    }
    error = failures ? "部分未读数量暂时无法更新" : nil
  }
  func poll(api: API) async {
    while !Task.isCancelled {
      await refresh(api: api)
      do { try await Task.sleep(for: .seconds(45)) } catch { return }
    }
  }
}

struct MessageUnreadBadge: View {
  let count: Int
  var body: some View {
    if count > 0 {
      Text(count > 99 ? "99+" : String(count)).font(.caption2.bold().monospacedDigit())
        .foregroundStyle(.white).padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
        .background(biliPink, in: .capsule).fixedSize()
        .accessibilityLabel("\(count) 条未读")
    }
  }
}

struct NativeNotice: Identifiable {
  let id: String
  let mid: Int
  let name: String
  let face: String
  let text: String
  let quote: String
  let date: Date
  let url: URL?
  var commentTarget: NoticeCommentTarget? = nil
  var action: String = ""
  var headline: String { action.isEmpty ? name : name + action }
  var originalPageURL: URL? {
    if let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = parts.host?.lowercased(), host == "bilibili.com" || host.hasSuffix(".bilibili.com"),
      parts.scheme == nil || ["http", "https"].contains(parts.scheme?.lowercased() ?? "")
    {
      parts.scheme = "https"
      return parts.url
    }
    if let target = commentTarget, target.type == 1 {
      return URL(string: "https://www.bilibili.com/video/av\(target.oid)/#reply\(target.replyID)")
    }
    if let url, url.scheme == "bilibili", url.host == "video",
      let aid = Int(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), aid > 0 {
      return URL(string: "https://www.bilibili.com/video/av\(aid)/")
    }
    return nil
  }
  static func parse(_ raw: [String: Any]) -> NativeNotice? {
    parse(raw, kind: raw["like_time"] != nil ? 3 : raw["at_time"] != nil ? 2 : 1)
  }
  static func parse(_ raw: [String: Any], kind: Int) -> NativeNotice? {
    guard let id = (raw["id"] as? NSNumber)?.stringValue ?? raw["id"] as? String else { return nil }
    let user = raw["user"] as? [String: Any] ?? (raw["users"] as? [[String: Any]])?.first ?? [:]
    let item = raw["item"] as? [String: Any] ?? [:]
    let time =
      raw["reply_time"] as? Double ?? raw["at_time"] as? Double ?? raw["like_time"] as? Double ?? 0
    func firstText(_ keys: [String]) -> String {
      keys.compactMap { item[$0] as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
    let count = MessageUnreadCounts.number(raw["counts"]) ?? 1
    let business = firstText(["business"])
    let object: String
    if business.contains("评论") || item["type"] as? String == "reply" { object = "评论" }
    else if business.contains("视频") || item["type"] as? String == "video" { object = "视频" }
    else if business.contains("动态") { object = "动态" }
    else if business.contains("弹幕") { object = "弹幕" }
    else if business.contains("专栏") { object = "专栏" }
    else { object = "内容" }
    let action = kind == 3 ? (count > 1 ? "等 \(count) 人" : "") + "赞了你的\(object)"
      : kind == 2 ? "提到了你" : "回复了你"
    return NativeNotice(
      id: id, mid: user["mid"] as? Int ?? 0,
      name: user["nickname"] as? String ?? user["name"] as? String ?? "用户",
      face: user["avatar"] as? String ?? user["face"] as? String ?? "",
      text: firstText(kind == 3 ? ["title", "source_content", "desc"] : ["source_content", "title", "desc"]),
      quote: kind == 3 ? "" : firstText(["target_reply_content", "desc"]),
      date: Date(timeIntervalSince1970: time),
      url: URL(string: firstText(["uri", "native_uri"])),
      commentTarget: kind == 3 ? nil : NoticeCommentTarget.parse(item), action: action)
  }
}

struct NoticeCommentTarget: Identifiable, Equatable {
  let oid: Int
  let type: Int
  let replyID: Int
  let rootID: Int
  var id: String { "\(type):\(oid):\(replyID)" }
  static func parse(_ item: [String: Any]) -> Self? {
    func number(_ key: String) -> Int { (item[key] as? NSNumber)?.intValue ?? Int(item[key] as? String ?? "") ?? 0 }
    let type = number("business_id")
    let oid = number("subject_id")
    // The incoming source is the reply author; target_id is the older comment they replied to.
    let source = number("source_id")
    guard [1, 11, 17].contains(type), oid > 0, source > 0 else { return nil }
    return Self(oid: oid, type: type, replyID: source, rootID: number("root_id"))
  }
}
