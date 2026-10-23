import CryptoKit
import Foundation

/// Separate, account-bound app authorization. Never sent as a web Cookie.
struct AppCoinAuthorization: Codable, Sendable {
  let accountID: Int
  let accessToken: String
  let expires: Date
  static let vaultAccount = "coin-app-authorization"

  func isValid(for account: String?, now: Date = Date()) -> Bool {
    accountID > 0 && account == String(accountID) && !accessToken.isEmpty && expires > now.addingTimeInterval(30)
  }
  static func parse(_ data: [String: Any], expectedAccount: String?, now: Date = Date()) throws -> Self {
    let token = data["token_info"] as? [String: Any] ?? data
    guard let mid = token["mid"] as? Int, mid > 0, String(mid) == expectedAccount,
      let access = token["access_token"] as? String, !access.isEmpty, access.utf8.count <= 4096,
      let ttl = token["expires_in"] as? Int, ttl > 30, ttl <= 366 * 86400 else {
      throw BiliError(text: "授权账号不匹配或返回不完整，保留原登录")
    }
    return Self(accountID: mid, accessToken: access, expires: now.addingTimeInterval(Double(ttl)))
  }
}

/// Both credentials are issued by the same confirmed QR login and saved atomically.
struct StoredLogin: Codable, Sendable {
  var cookies: [String: String]
  var appCoinAuthorization: AppCoinAuthorization?

  static func decode(_ data: Data) -> Self? {
    if let session = try? JSONDecoder().decode(Self.self, from: data) { return session }
    // Existing installations saved only web cookies. Keep those logins usable.
    return (try? JSONDecoder().decode([String: String].self, from: data))
      .map { Self(cookies: $0, appCoinAuthorization: nil) }
  }
  /// WebKit may refresh web cookies after a client login. Keep only a token for
  /// that same account, and never turn a web-only login into a client authorization.
  static func webLogin(cookies: [String: String], previous: AppCoinAuthorization?) throws -> Self {
    guard let mid = cookies["DedeUserID"], let account = Int(mid), account > 0,
      let session = cookies["SESSDATA"], !session.isEmpty,
      let csrf = cookies["bili_jct"], !csrf.isEmpty else {
      throw BiliError(text: "网页登录信息不完整，保留原登录")
    }
    let allowed: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
    let retained = cookies.filter { allowed.contains($0.key) }
    guard retained.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192
      && !$0.contains(where: { $0 == ";" || $0.isNewline }) }) else {
      throw BiliError(text: "网页登录信息无效，保留原登录")
    }
    return Self(cookies: retained, appCoinAuthorization: previous?.accountID == account ? previous : nil)
  }
  static func parse(_ data: [String: Any], now: Date = Date()) throws -> Self {
    guard let info = data["cookie_info"] as? [String: Any],
      let entries = info["cookies"] as? [[String: Any]] else {
      throw BiliError(text: "登录信息不完整，请刷新二维码重试")
    }
    let allowed: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
    var cookies: [String: String] = [:]
    for entry in entries {
      guard let name = entry["name"] as? String, allowed.contains(name) else { continue }
      guard let value = entry["value"] as? String, !value.isEmpty, value.utf8.count <= 8192,
        !value.contains(where: { $0 == ";" || $0.isNewline }),
        cookies[name] == nil || cookies[name] == value else {
        throw BiliError(text: "登录信息无效，请刷新二维码重试")
      }
      cookies[name] = value
    }
    guard cookies["SESSDATA"] != nil, cookies["bili_jct"] != nil else {
      throw BiliError(text: "登录信息不完整，请刷新二维码重试")
    }
    let token = try AppCoinAuthorization.parse(data, expectedAccount: cookies["DedeUserID"], now: now)
    return Self(cookies: cookies, appCoinAuthorization: token)
  }
}

enum AppCoinProtocol {
  // Published client protocol identifiers, not user credentials. See THIRD_PARTY.md.
  static let appKey = "dfca71928277209b"
  private static let signingSalt = "b5475a8825547a4fc26c7d518eaaa02e"
  static func signed(_ values: [String: String], now: Date = Date()) -> [String: String] {
    var parameters = values
    parameters.removeValue(forKey: "sign")
    parameters["appkey"] = appKey
    parameters["ts"] = String(Int(now.timeIntervalSince1970))
    let canonical = API.formBody(parameters)
    parameters["sign"] = Insecure.MD5.hash(data: canonical + Data(signingSalt.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return parameters
  }
}

extension API {
  func appCoinRequest(_ path: String, _ values: [String: String]) async throws -> [String: Any] {
    let host: String
    switch path {
    case "/x/passport-tv-login/qrcode/auth_code", "/x/passport-tv-login/qrcode/poll":
      host = "passport.bilibili.com"
    case "/x/v2/view/coin/add", "/x/v2/view/like/triple": host = "app.bilibili.com"
    default: throw BiliError(text: "客户端授权请求无效")
    }
    try Task.checkCancellation()
    let generation = authenticationGeneration
    var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
    request.httpMethod = "POST"
    request.httpBody = Self.formBody(AppCoinProtocol.signed(values))
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    Self.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard generation == authenticationGeneration else { throw CancellationError() }
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BiliError(text: "客户端授权请求失败，请稍后重试")
    }
    return root
  }
  func appCoinQRCode() async throws -> (code: String, url: String) {
    let root = try await appCoinRequest("/x/passport-tv-login/qrcode/auth_code",
      ["local_id": "0", "platform": "android", "mobi_app": "android_hd"])
    guard root["code"] as? Int == 0, let data = root["data"] as? [String: Any],
      let code = data["auth_code"] as? String, !code.isEmpty,
      let url = data["url"] as? String, let parsed = URL(string: url),
      parsed.scheme == "https", parsed.host == "passport.bilibili.com" else {
      throw BiliError(text: root["message"] as? String ?? "无法获取客户端授权二维码", code: root["code"] as? Int)
    }
    return (code, url)
  }
  func pollClientLogin(_ code: String) async throws -> StoredLogin? {
    let root = try await appCoinRequest("/x/passport-tv-login/qrcode/poll", ["auth_code": code, "local_id": "0"])
    let status = root["code"] as? Int
    if [86039, 86090, 86101].contains(status ?? -1) { return nil }
    guard status == 0, let data = root["data"] as? [String: Any] else {
      throw BiliError(text: root["message"] as? String ?? "授权二维码已失效，请刷新", code: status)
    }
    return try StoredLogin.parse(data)
  }
  func addAppCoins(aid: Int, amount: Int, alsoLike: Bool, credential: AppCoinAuthorization) async throws -> Bool {
    guard credential.isValid(for: cookies["DedeUserID"]), (1...2).contains(amount) else {
      throw BiliError(text: "请重新登录后再试", code: -101)
    }
    let root = try await appCoinRequest("/x/v2/view/coin/add", ["access_key": credential.accessToken,
      "aid": String(aid), "multiply": String(amount), "select_like": alsoLike ? "1" : "0"])
    guard root["code"] as? Int == 0 else {
      // Never retry a write on another endpoint: the first result may be uncertain.
      throw BiliError(text: root["message"] as? String ?? "投币未成功，请刷新状态", code: root["code"] as? Int)
    }
    // code 0 confirms the coin. Only claim an attached like when explicitly returned.
    return (root["data"] as? [String: Any])?["like"] as? Bool ?? false
  }
  func appTriple(aid: Int, bvid: String, credential: AppCoinAuthorization) async throws -> TripleResult {
    guard credential.isValid(for: cookies["DedeUserID"]) else { throw BiliError(text: "请重新登录后再试", code: -101) }
    let generation = authenticationGeneration
    let before = try await videoRelation(aid, bvid: bvid)
    guard generation == authenticationGeneration else { throw CancellationError() }
    let root = try await appCoinRequest("/x/v2/view/like/triple", ["access_key": credential.accessToken, "aid": String(aid)])
    guard root["code"] as? Int == 0 else {
      throw BiliError(text: root["message"] as? String ?? "三连未成功，请刷新后查看", code: root["code"] as? Int)
    }
    // Read confirmed state: app variants do not all return the web `multiply` field.
    var after = try await videoRelation(aid, bvid: bvid)
    for delay in [250, 500, 1000, 2000] where !after.liked || !after.favorited || after.coins == 0 {
      // The relation read can briefly lag a confirmed write. Retry reads only.
      try await Task.sleep(for: .milliseconds(delay))
      guard generation == authenticationGeneration else { throw CancellationError() }
      after = try await videoRelation(aid, bvid: bvid)
    }
    guard generation == authenticationGeneration else { throw CancellationError() }
    let added = max(0, min(2, after.coins - before.coins))
    return TripleResult(like: after.liked, coin: added > 0, favorite: after.favorited, count: added,
      confirmedRelation: after)
  }
}
