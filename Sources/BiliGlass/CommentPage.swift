import Foundation

struct CommentPage {
  let replies: [Reply]
  let count: Int
  let nextOffset: String?
  static func parse(_ data: [String: Any], first: Bool) throws -> CommentPage {
    guard let cursor = data["cursor"] as? [String: Any], let isEnd = cursor["is_end"] as? Bool else {
      throw BiliError(text: "评论分页信息不完整，请重试")
    }
    let pagination = cursor["pagination_reply"] as? [String: Any] ?? [:]
    let offset = pagination["next_offset"] as? String ?? (pagination["next_offset"] as? NSNumber)?.stringValue
    guard isEnd || offset?.isEmpty == false else { throw BiliError(text: "评论下一页信息缺失，请重试") }
    var rows: [[String: Any]] = []
    if first {
      if let top = data["top"] as? [String: Any] {
        rows += [top["admin"], top["upper"]].compactMap { $0 as? [String: Any] }
      }
      rows += data["top_replies"] as? [[String: Any]] ?? []
      if let pinned = (data["upper"] as? [String: Any])?["top"] as? [String: Any] { rows.append(pinned) }
    }
    rows += data["replies"] as? [[String: Any]] ?? []
    return CommentPage(replies: Reply.deduplicated(rows.compactMap(Reply.parse), excluding: []),
                       count: cursor["all_count"] as? Int ?? 0, nextOffset: isEnd ? nil : offset)
  }
  static func pagination(_ offset: String?) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["offset": offset ?? ""], options: [.sortedKeys]), as: UTF8.self)
  }
}
