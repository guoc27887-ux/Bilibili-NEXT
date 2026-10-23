import Foundation

struct DynamicAttachment {
  let kind: String
  let title: String
  let description: String
  let cover: String
  let url: URL?

  static func parse(major: [String: Any]) -> Self? {
    func string(_ value: Any?) -> String { value as? String ?? "" }
    func link(_ value: Any?) -> URL? {
      let raw = string(value)
      guard var parts = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw),
        ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
        parts.user == nil, parts.password == nil,
        let host = parts.host?.lowercased(),
        host == "bilibili.com" || host.hasSuffix(".bilibili.com")
      else { return nil }
      parts.scheme = "https"
      return parts.url
    }
    if let live = major["live_rcmd"] as? [String: Any],
      let data = string(live["content"]).data(using: .utf8), data.count < 100_000,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let info = object["live_play_info"] as? [String: Any]
    {
      let room = (info["room_id"] as? NSNumber)?.stringValue ?? string(info["room_id"])
      return Self(
        kind: "直播", title: string(info["title"]), description: string(info["area_name"]),
        cover: string(info["cover"]),
        url: link(info["link"])
          ?? (room.isEmpty ? nil : URL(string: "https://live.bilibili.com/" + room)))
    }
    for (key, kind) in [
      ("article", "专栏"), ("pgc", "番剧"), ("music", "音乐"), ("common", "分享"), ("live", "直播"),
      ("courses", "课程"), ("medialist", "播单"),
    ] {
      guard let row = major[key] as? [String: Any] else { continue }
      let title = string(row["title"] ?? row["name"])
      let cover = string(row["cover"] ?? (row["covers"] as? [String])?.first)
      return Self(
        kind: kind, title: title.isEmpty ? "分享的" + kind : title,
        description: string(row["desc"] ?? row["subtitle"]), cover: cover,
        url: link(row["jump_url"] ?? row["url"]))
    }
    return nil
  }
}
