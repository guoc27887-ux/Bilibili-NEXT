import Foundation

struct DanmakuCloudRule: Codable, Identifiable, Sendable, Equatable {
  let id: Int
  let type: Int
  let filter: String
  static func parse(_ raw: Any?) -> [Self] {
    (raw as? [[String: Any]] ?? []).compactMap {
      guard let id = $0["id"] as? Int, let type = $0["type"] as? Int,
        let filter = $0["filter"] as? String
      else { return nil }
      return Self(id: id, type: type, filter: filter)
    }
  }
}
extension API {
  func cloudDanmakuRules() async throws -> [DanmakuCloudRule] {
    guard signedIn else { throw BiliError(text: "登录后同步云端屏蔽规则") }
    let auth = authenticationGeneration
    let data = try await request("/x/dm/filter/user")
    guard auth == authenticationGeneration else { throw CancellationError() }
    let rules = DanmakuCloudRule.parse(data["rule"])
    UserDefaults.standard.set(try JSONEncoder().encode(rules), forKey: "danmakuCloudRules")
    UserDefaults.standard.set(cookies["DedeUserID"] ?? "guest", forKey: "danmakuCloudOwner")
    return rules
  }
}
