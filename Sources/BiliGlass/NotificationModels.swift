import Foundation

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
    return nil
  }
  static func parse(_ raw: [String: Any]) -> NativeNotice? {
    guard let id = (raw["id"] as? NSNumber)?.stringValue ?? raw["id"] as? String else { return nil }
    let user = raw["user"] as? [String: Any] ?? (raw["users"] as? [[String: Any]])?.first ?? [:]
    let item = raw["item"] as? [String: Any] ?? [:]
    let time =
      raw["reply_time"] as? Double ?? raw["at_time"] as? Double ?? raw["like_time"] as? Double ?? 0
    return NativeNotice(
      id: id, mid: user["mid"] as? Int ?? 0,
      name: user["nickname"] as? String ?? user["name"] as? String ?? "用户",
      face: user["avatar"] as? String ?? user["face"] as? String ?? "",
      text: item["source_content"] as? String ?? item["title"] as? String ?? "收到新的互动",
      quote: item["target_reply_content"] as? String ?? item["desc"] as? String ?? "",
      date: Date(timeIntervalSince1970: time),
      url: (item["uri"] as? String).flatMap(URL.init(string:)),
      commentTarget: NoticeCommentTarget.parse(item))
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
