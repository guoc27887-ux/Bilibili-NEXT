import Foundation
import SwiftUI

struct Conversation: Identifiable, Hashable {
  var id: String { "\(kind):\(mid)" }
  let mid: Int
  let kind: Int
  var name: String
  var face: String
  var preview: String
  var unread: Int
  let timestamp: Int64
  let system: Bool
  static func parse(_ raw: [String: Any]) -> Conversation? {
    guard let mid = raw["talker_id"] as? Int else { return nil }
    let account = raw["account_info"] as? [String: Any] ?? [:]
    let message = (raw["last_msg"] as? [String: Any]).flatMap(PrivateMessage.parse)
    let groupName = raw["group_name"] as? String ?? ""
    return Conversation(
      mid: mid, kind: raw["session_type"] as? Int ?? 1,
      name: account["name"] as? String ?? (groupName.isEmpty ? "UID \(mid)" : groupName),
      face: account["pic_url"] as? String ?? raw["group_cover"] as? String ?? "",
      preview: message?.text ?? "", unread: raw["unread_count"] as? Int ?? 0,
      timestamp: (raw["session_ts"] as? NSNumber)?.int64Value ?? 0,
      system: (raw["system_msg_type"] as? Int ?? 0) > 0)
  }
}
struct PrivateMessage: Identifiable {
  let id: String
  let sequence: String
  let sender: Int
  let text: String
  let image: String?
  let video: String?
  let link: URL?
  let date: Date
  let retracted: Bool
  var isNotice: Bool = false
  var share: MessageShare? = nil
  static func parse(_ raw: [String: Any]) -> PrivateMessage? {
    let id =
      (raw["msg_key"] as? NSNumber)?.stringValue ?? raw["msg_key"] as? String
      ?? (raw["msg_seqno"] as? NSNumber)?.stringValue
    guard let id else { return nil }
    let type = raw["msg_type"] as? Int ?? 0
    let retracted = [1, 2].contains(raw["msg_status"] as? Int ?? 0) || type == 5
    let content = raw["content"] as? String ?? ""
    let object =
      (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any] ?? [:]
    var text =
      object["content"] as? String ?? object["text"] as? String ?? object["title"] as? String ?? ""
    if type == 18 {
      let fragments = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? []
      text = fragments.compactMap { $0["text"] as? String }.joined()
      if text.isEmpty { text = "系统提示" }
    }
    if retracted {
      text = "消息已撤回"
    } else if text.isEmpty {
      text = [2, 6].contains(type) ? "图片" : "暂不支持的消息类型"
    }
    let image =
      retracted ? nil : (object["url"] as? String).flatMap { [2, 6].contains(type) ? $0 : nil }
    let video = retracted ? nil : object["bvid"] as? String
    let link =
      retracted
      ? nil : (object["jump_uri"] as? String ?? object["url"] as? String).flatMap(URL.init(string:))
    return PrivateMessage(
      id: id, sequence: (raw["msg_seqno"] as? NSNumber)?.stringValue ?? "0",
      sender: raw["sender_uid"] as? Int ?? 0, text: text, image: image,
      video: video, link: link?.scheme == "https" ? link : nil,
      date: Date(timeIntervalSince1970: (raw["timestamp"] as? NSNumber)?.doubleValue ?? 0),
      retracted: retracted, isNotice: type == 18,
      share: retracted ? nil : MessageShare.parse(object, type: type))
  }
}

@MainActor @Observable final class InboxModel {
  var conversations: [Conversation] = []
  var selected: Conversation?
  var messages: [PrivateMessage] = []
  var drafts: [String: String] = [:]
  var loading = false
  var loadingMessages = false
  var sending = false
  var hasMore = false
  var hasOlder = false
  var error: String?
  var messageError: String?
  private var identity = UUID()
  private var threadIdentity = UUID()
  private var sendIdentity = UUID()
  private var cursor: Int64?
  private var systemOnly = false
  func load(api: API, more: Bool = false, systemOnly: Bool = false) async {
    if !more && self.systemOnly != systemOnly {
      identity = UUID()
      self.systemOnly = systemOnly
      loading = false
      conversations = []
      cursor = nil
      hasMore = false
      selected = nil
      threadIdentity = UUID()
      messages = []
      loadingMessages = false
      hasOlder = false
      messageError = nil
    }
    guard !loading else { return }
    loading = true
    error = nil
    let token = identity
    let auth = api.authenticationGeneration
    defer { if token == identity { loading = false } }
    do {
      var query = [
        "session_type": systemOnly ? "7" : "4", "group_fold": "0", "unfollow_fold": "0",
        "sort_rule": "2", "size": "30", "mobi_app": "web",
      ]
      if more, let cursor { query["end_ts"] = String(cursor) }
      let data = try await api.messageRequest("/session_svr/v1/session_svr/get_sessions", query)
      try Task.checkCancellation()
      guard token == identity, auth == api.authenticationGeneration else { return }
      var rows = (data["session_list"] as? [[String: Any]] ?? []).compactMap(Conversation.parse)
      let mids = rows.filter { $0.kind == 1 }.map { String($0.mid) }.joined(separator: ",")
      if !mids.isEmpty,
        let cards = try? await api.messageRequest("/account/v1/user/cards", ["uids": mids]),
        let entries = cards["items"] as? [[String: Any]]
      {
        let names = Dictionary(
          entries.compactMap { raw -> (Int, [String: Any])? in
            guard let mid = raw["mid"] as? Int else { return nil }
            return (mid, raw)
          }, uniquingKeysWith: { first, _ in first })
        for i in rows.indices {
          if let card = names[rows[i].mid], !rows[i].system {
            rows[i].name = card["name"] as? String ?? rows[i].name
            rows[i].face = card["face"] as? String ?? rows[i].face
          }
        }
      }
      guard token == identity, auth == api.authenticationGeneration, !Task.isCancelled else {
        return
      }
      let oldIDs = more ? Set(conversations.map(\.id)) : []
      var ids = oldIDs
      let unique = rows.filter { ids.insert($0.id).inserted }
      conversations = more ? conversations + unique : unique
      if let selected, !conversations.contains(where: { $0.id == selected.id }) {
        conversations.insert(selected, at: 0)
      }
      cursor = rows.map(\.timestamp).min()
      hasMore = (data["has_more"] as? Int ?? 0) != 0
    } catch {
      if token == identity && !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
  func select(_ conversation: Conversation) {
    selected = conversation
    threadIdentity = UUID()
    messages = []
    messageError = nil
    loadingMessages = false
    hasOlder = false
  }
  func loadMessages(api: API, older: Bool = false, markRead: Bool = true) async {
    guard let conversation = selected, !loadingMessages else { return }
    let token = threadIdentity
    let auth = api.authenticationGeneration
    loadingMessages = true
    messageError = nil
    defer { if token == threadIdentity { loadingMessages = false } }
    do {
      var query = [
        "talker_id": String(conversation.mid), "session_type": String(conversation.kind),
        "size": "30", "mobi_app": "web",
      ]
      if older, let first = messages.first { query["end_seqno"] = first.sequence }
      let data = try await api.messageRequest("/svr_sync/v1/svr_sync/fetch_session_msgs", query)
      try Task.checkCancellation()
      guard token == threadIdentity, auth == api.authenticationGeneration else { return }
      var ids = Set<String>()
      let rows = (data["messages"] as? [[String: Any]] ?? []).compactMap(PrivateMessage.parse)
        .filter { ids.insert($0.id).inserted }.sorted { $0.date < $1.date }
      let wasEmpty = messages.isEmpty
      var merged = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      for row in rows { merged[row.id] = row }
      messages = merged.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
      if older || wasEmpty {
        hasOlder = data["has_more"] as? Bool ?? ((data["has_more"] as? Int ?? 0) != 0)
      }
      if !older, markRead, conversation.unread > 0 {
        _ = try? await api.messageRequest(
          "/session_svr/v1/session_svr/update_ack",
          [
            "talker_id": String(conversation.mid), "session_type": String(conversation.kind),
            "ack_seqno": messages.last?.sequence ?? "0",
          ], write: true)
        guard token == threadIdentity else { return }
        if let i = conversations.firstIndex(where: { $0.id == conversation.id }) {
          conversations[i].unread = 0
        }
      }
    } catch {
      if token == threadIdentity && !Task.isCancelled { messageError = error.localizedDescription }
    }
  }
  func send(api: API, account: Account) async {
    guard let conversation = selected, !sending else { return }
    let text = (drafts[conversation.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let content = (try? JSONSerialization.data(withJSONObject: ["content": text])) ?? Data()
    guard content.count <= 2000 else {
      messageError = "消息超过 2000 字节，请缩短后发送"
      return
    }
    sending = true
    messageError = nil
    sendIdentity = UUID()
    let operation = sendIdentity
    let auth = api.authenticationGeneration
    let token = threadIdentity
    defer { if operation == sendIdentity { sending = false } }
    do {
      let now = Int(Date().timeIntervalSince1970)
      let data = try await api.messageRequest(
        "/web_im/v1/web_im/send_msg",
        [
          "msg[sender_uid]": String(account.mid), "msg[receiver_id]": String(conversation.mid),
          "msg[receiver_type]": String(conversation.kind), "msg[msg_type]": "1",
          "msg[msg_status]": "0",
          "msg[dev_id]": UUID().uuidString.uppercased(), "msg[timestamp]": String(now),
          "msg[new_face_version]": "1", "msg[content]": String(decoding: content, as: UTF8.self),
          "mobi_app": "web",
        ], write: true)
      guard auth == api.authenticationGeneration else { return }
      if drafts[conversation.id]?.trimmingCharacters(in: .whitespacesAndNewlines) == text {
        drafts[conversation.id] = ""
      }
      guard token == threadIdentity else { return }
      let raw: [String: Any] = [
        "msg_key": data["msg_key"] ?? UUID().uuidString, "msg_seqno": data["msg_seqno"] ?? 0,
        "sender_uid": account.mid, "msg_type": 1, "timestamp": now,
        "content": String(decoding: content, as: UTF8.self),
      ]
      if let message = PrivateMessage.parse(raw) { messages.append(message) }
      if let i = conversations.firstIndex(where: { $0.id == conversation.id }) {
        conversations[i].preview = text
      }
    } catch { if token == threadIdentity { messageError = error.localizedDescription } }
  }
  func clear() {
    identity = UUID()
    threadIdentity = UUID()
    sendIdentity = UUID()
    conversations = []
    selected = nil
    messages = []
    drafts = [:]
    loading = false
    loadingMessages = false
    sending = false
    cursor = nil
    hasMore = false
    hasOlder = false
    systemOnly = false
    error = nil
    messageError = nil
  }
}
