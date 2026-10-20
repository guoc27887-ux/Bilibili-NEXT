import BiliModels
import BiliNetworking
import CryptoKit
import Foundation
import Security
import VideoToolbox

struct BiliError: LocalizedError {
  let text: String
  var code: Int? = nil
  var requiresVerification: Bool { [-351, -352, -412].contains(code ?? 0) || text.contains("验证") }
  var errorDescription: String? { text }
}
struct Video: Identifiable, Codable, Hashable {
  var id: String { bvid }
  let bvid: String
  let title: String
  let cover: String
  let author: String
  let duration: Int
  let views: Int
  var publishedAt: Date? = nil
  static func deduplicated(_ videos: [Video], excluding: Set<String> = []) -> [Video] {
    var seen = excluding
    return videos.filter { seen.insert($0.id).inserted }
  }
  static func parse(_ j: [String: Any]) -> Video? {
    guard let bvid = j["bvid"] as? String, bvid.hasPrefix("BV") else { return nil }
    let owner = j["owner"] as? [String: Any] ?? [:]
    let stat = j["stat"] as? [String: Any] ?? [:]
    let raw = j["duration"] as? String ?? j["length"] as? String ?? "0"
    let seconds = raw.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    return Video(
      bvid: bvid, title: cleanTitle(j["title"] as? String ?? "视频"),
      cover: j["pic"] as? String ?? "",
      author: owner["name"] as? String ?? j["author"] as? String ?? "",
      duration: j["duration"] as? Int ?? seconds,
      views: stat["view"] as? Int ?? j["play"] as? Int ?? 0,
      publishedAt: ((j["pubdate"] as? NSNumber)?.doubleValue ?? (j["created"] as? NSNumber)?.doubleValue).flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
  }
}
struct Page: Identifiable {
  let id: Int
  let title: String
  let number: Int
  var duration: Int = 0
}
struct Detail {
  let video: Video
  let description: String
  let pages: [Page]
  var aid: Int = 0
  var ownerID: Int = 0
  var ownerFace: String = ""
  var copyright: Int = 1
  var counts = VideoCounts()
}
struct Streams {
  let videos: [MediaRepresentation]
  let audio: MediaRepresentation
  let names: [Int: String]
}
struct Account {
  let name: String
  let mid: Int
  let face: String
}
func cleanTitle(_ s: String) -> String {
  s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(
    of: "&amp;", with: "&"
  ).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
}
func videoID(_ s: String) -> String? {
  s.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression).map { String(s[$0]) }
}
func safeFilename(_ s: String) -> String {
  let result = s.components(
    separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n\r").union(.controlCharacters)
  ).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
  return String((result.isEmpty ? "视频" : result).prefix(100))
}

final class Vault {
  static let service = "local.BiliGlass.session"
  static func save(_ data: Data) throws {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "cookies",
    ]
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var insert = q
      insert[kSecValueData as String] = data
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(insert as CFDictionary, nil)
      guard added == errSecSuccess else { throw BiliError(text: "无法保存登录：\(added)") }
    } else if status != errSecSuccess {
      throw BiliError(text: "无法保存登录：\(status)")
    }
  }
  static func load() -> Data? {
    var value: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: "cookies", kSecReturnData as String: true,
      ] as CFDictionary, &value)
    return status == errSecSuccess ? value as? Data : nil
  }
  static func clear() {
    SecItemDelete(
      [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        as CFDictionary)
  }
}

@MainActor final class API {
  nonisolated static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  nonisolated static let mediaHeaders = [
    "User-Agent": userAgent, "Referer": "https://www.bilibili.com/",
  ]
  let session: URLSession
  var cookies: [String: String] = [:]
  private var wbiKey: String?
  private var navigationTask: (id: UUID, task: Task<[String: Any], Error>)?
  var authenticationGeneration = UUID()
  var dynamicCursor = ""
  var dynamicHasMore = true
  private let searchID = UUID().uuidString.lowercased() + "infoc"
  init(loadCredentials: Bool = true, transport: URLSession? = nil) {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.timeoutIntervalForRequest = 25
    c.urlCache = nil
    session = transport ?? URLSession(configuration: c)
    if loadCredentials, let data = Vault.load(),
      let saved = try? JSONDecoder().decode([String: String].self, from: data)
    {
      cookies = saved
    }
  }
  func restoreCredentials() async {
    let generation = authenticationGeneration
    let data = await Task.detached(priority: .userInitiated) { Vault.load() }.value
    guard !Task.isCancelled, generation == authenticationGeneration, let data,
      let saved = try? JSONDecoder().decode([String: String].self, from: data)
    else { return }
    cookies = saved
  }
  var signedIn: Bool { cookies["SESSDATA"] != nil }
  func logout() {
    navigationTask?.task.cancel()
    navigationTask = nil
    authenticationGeneration = UUID()
    cookies = [:]
    Vault.clear()
    WebSession.shared.reset()
    wbiKey = nil
  }
  func request(_ path: String, _ query: [String: String] = [:], signed: Bool = false) async throws
    -> [String: Any]
  {
    try Task.checkCancellation()
    let authentication = authenticationGeneration
    var params = query
    if signed {
      if wbiKey == nil { _ = try await nav() }
      if let key = wbiKey { params = Self.sign(params, key: key) }
    }
    let host =
      path.hasPrefix("/x/passport") ? "https://passport.bilibili.com" : "https://api.bilibili.com"
    var u = URLComponents(string: host + path)!
    u.queryItems = params.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    var req = URLRequest(url: u.url!)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    API.mediaHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    if let bvid = params["bvid"] {
      req.setValue("https://www.bilibili.com/video/" + bvid + "/", forHTTPHeaderField: "Referer")
    }
    if path == "/x/space/wbi/arc/search" || path.contains("/web-space/"), let mid = params["mid"] {
      req.setValue(
        "https://space.bilibili.com/" + mid + "/upload/video", forHTTPHeaderField: "Referer")
    }
    req.setValue(
      (cookies.merging(
        (path.contains("search/") || path == "/x/space/wbi/arc/search") ? ["buvid3": searchID] : [:]
      ) { a, _ in a }).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
        separator: "; "),
      forHTTPHeaderField: "Cookie")
    let (data, response) = try await session.data(for: req)
    try Task.checkCancellation()
    guard authentication == authenticationGeneration else { throw CancellationError() }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      #if DEBUG
        print("API HTTP", code, path)
      #endif
      throw BiliError(text: code == 412 ? "请求受限（412），请稍后重试或登录" : "连接失败（\(code)），请稍后重试")
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BiliError(text: "返回数据无效")
    }
    let code = root["code"] as? Int ?? -1
    guard code == 0 || (path == "/x/web-interface/nav" && code == -101) else {
      throw BiliError(
        text: code == -101 ? "请重新登录" : "\(root["message"] as? String ?? "请求失败")（\(code)）", code: code)
    }
    if path.hasSuffix("qrcode/poll"), let result = root["data"] as? [String: Any],
      result["code"] as? Int == 0
    {
      // Only accept cookies from the exact passport host on successful QR confirmation.
      let fields = http.allHeaderFields.reduce(into: [String: String]()) {
        if let k = $1.key as? String, let v = $1.value as? String { $0[k] = v }
      }
      for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: req.url!)
      where ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"].contains(c.name) {
        cookies[c.name] = c.value
      }
      if !signedIn, let s = result["url"] as? String, let url = URLComponents(string: s) {
        for pair in url.queryItems ?? []
        where ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"].contains(pair.name) {
          cookies[pair.name] = pair.value
        }
      }
      guard signedIn else { throw BiliError(text: "登录凭据缺失，请重新扫码") }
      authenticationGeneration = UUID()
      try Vault.save(JSONEncoder().encode(cookies))
    }
    if let object = root["data"] as? [String: Any] { return object }
    if let array = root["data"] as? [Any] { return ["items": array] }
    return ["value": root["data"] ?? NSNull()]
  }
  func messageRequest(_ path: String, _ values: [String: String] = [:], write: Bool = false)
    async throws -> [String: Any]
  {
    try Task.checkCancellation()
    let reads: Set<String> = [
      "/session_svr/v1/session_svr/get_sessions", "/svr_sync/v1/svr_sync/fetch_session_msgs",
      "/account/v1/user/cards",
    ]
    let writes: Set<String> = [
      "/web_im/v1/web_im/send_msg", "/session_svr/v1/session_svr/update_ack",
    ]
    guard (write ? writes : reads).contains(path), signedIn else { throw BiliError(text: "请先登录") }
    var params = values
    var components = URLComponents(string: "https://api.vc.bilibili.com" + path)!
    if write {
      guard let csrf = cookies["bili_jct"] else { throw BiliError(text: "登录信息已失效") }
      params["csrf"] = csrf
      params["csrf_token"] = csrf
      if path.hasSuffix("send_msg") {
        if wbiKey == nil { _ = try await nav() }
        let query = [
          "w_sender_uid": params["msg[sender_uid]"] ?? "",
          "w_receiver_id": params["msg[receiver_id]"] ?? "",
          "w_dev_id": params["msg[dev_id]"] ?? "",
        ]
        components.queryItems = (wbiKey.map { Self.sign(query, key: $0) } ?? query).map {
          URLQueryItem(name: $0.key, value: $0.value)
        }
      }
    } else {
      components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    var request = URLRequest(url: components.url!)
    request.httpMethod = write ? "POST" : "GET"
    if write {
      request.httpBody = Self.formBody(params)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://message.bilibili.com/", forHTTPHeaderField: "Referer")
    request.setValue(
      cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw BiliError(text: "消息连接失败，请重试")
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let code = root["code"] as? Int
    else { throw BiliError(text: "消息数据无效") }
    guard code == 0 else {
      throw BiliError(
        text: "\(root["message"] as? String ?? root["msg"] as? String ?? "消息请求失败")（\(code)）")
    }
    return root["data"] as? [String: Any] ?? ["items": root["data"] as? [Any] ?? []]
  }
  func nav() async throws -> Account? {
    let generation = authenticationGeneration
    let pending: Task<[String: Any], Error>
    let requestID: UUID
    if let navigationTask { pending = navigationTask.task; requestID = navigationTask.id }
    else {
      pending = Task { try await request("/x/web-interface/nav") }
      requestID = UUID()
      navigationTask = (requestID, pending)
    }
    defer { if navigationTask?.id == requestID { navigationTask = nil } }
    let data = try await pending.value
    guard generation == authenticationGeneration else { throw CancellationError() }
    if let wbi = data["wbi_img"] as? [String: String], let a = wbi["img_url"],
      let b = wbi["sub_url"], let imageURL = URL(string: a), let subURL = URL(string: b)
    {
      wbiKey = Self.mixin(
        imageURL.deletingPathExtension().lastPathComponent
          + subURL.deletingPathExtension().lastPathComponent)
    }
    guard data["isLogin"] as? Bool == true else { return nil }
    return Account(
      name: data["uname"] as? String ?? "已登录", mid: data["mid"] as? Int ?? 0,
      face: data["face"] as? String ?? "")
  }
  func popular(page: Int) async throws -> [Video] {
    let d = try await request("/x/web-interface/popular", ["pn": "\(page)", "ps": "24"])
    return (d["list"] as? [[String: Any]] ?? []).compactMap(Video.parse)
  }
  func search(_ term: String, page: Int) async throws -> [Video] {
    let d = try await request(
      "/x/web-interface/wbi/search/type",
      ["search_type": "video", "keyword": term, "page": "\(page)", "page_size": "24"], signed: true)
    return (d["result"] as? [[String: Any]] ?? []).compactMap(Video.parse)
  }
  func detail(_ bvid: String) async throws -> Detail {
    let d = try await request("/x/web-interface/wbi/view", ["bvid": bvid], signed: true)
    guard let video = Video.parse(d) else { throw BiliError(text: "视频不可用") }
    return Detail(
      video: video, description: d["desc"] as? String ?? "",
      pages: (d["pages"] as? [[String: Any]] ?? []).compactMap { p in
        guard let cid = p["cid"] as? Int else { return nil }
        return Page(id: cid, title: p["part"] as? String ?? "正片", number: p["page"] as? Int ?? 1, duration: p["duration"] as? Int ?? 0)
      }, aid: d["aid"] as? Int ?? 0, ownerID: (d["owner"] as? [String: Any])?["mid"] as? Int ?? 0,
      ownerFace: (d["owner"] as? [String: Any])?["face"] as? String ?? "",
      copyright: d["copyright"] as? Int ?? 1,
      counts: VideoCounts(d["stat"] as? [String: Any] ?? [:]))
  }
  func streams(bvid: String, cid: Int, quality: Int = 127) async throws -> Streams {
    let d = try await request(
      "/x/player/playurl",
      [
        "bvid": bvid, "cid": "\(cid)", "qn": "\(quality)", "fnval": "4048",
        "web_location": "1315873", "gaia_source": "pre-load", "isGaiaAvoided": "true",
        "try_look": signedIn ? "0" : "1", "fourk": "1",
        "fnver": "0",
      ])
    guard let dash = d["dash"] as? [String: Any] else { throw BiliError(text: "没有可播放的媒体，请登录后重试") }
    let videos = try (dash["video"] as? [[String: Any]] ?? []).filter { item in
      let codec = item["codecs"] as? String ?? ""
      return codec.hasPrefix("avc1") || codec.hasPrefix("hvc1") || codec.hasPrefix("hev1")
        || codec.hasPrefix("dvh1") || codec.hasPrefix("dvhe")
        || (codec.hasPrefix("av01") && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
    }
    .map { try representation($0, kind: .video) }
    let audios = try (dash["audio"] as? [[String: Any]] ?? []).filter {
      ($0["codecs"] as? String ?? "").hasPrefix("mp4a")
    }.map { try representation($0, kind: .audio) }
    guard !videos.isEmpty, let audio = audios.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) })
    else { throw BiliError(text: "没有系统支持的媒体编码") }
    var names: [Int: String] = [:]
    for f in d["support_formats"] as? [[String: Any]] ?? [] {
      if let id = f["quality"] as? Int {
        names[id] = f["new_description"] as? String ?? f["display_desc"] as? String
      }
    }
    return Streams(videos: videos.sorted { $0.id > $1.id }, audio: audio, names: names)
  }
  private func representation(_ j: [String: Any], kind: MediaKind) throws -> MediaRepresentation {
    guard let raw = j["baseUrl"] as? String ?? j["base_url"] as? String, let url = URL(string: raw),
      BiliMediaCDNURLPolicy().allows(url),
      let seg = j["SegmentBase"] as? [String: String] ?? j["segment_base"] as? [String: String]
    else { throw BiliError(text: "媒体地址无效") }
    func range(_ raw: String?) throws -> MediaByteRange {
      let p = (raw ?? "").split(separator: "-").compactMap { Int64($0) }
      guard p.count == 2 else { throw BiliError(text: "媒体索引无效") }
      return try MediaByteRange(start: p[0], endInclusive: p[1])
    }
    let attrs: VideoRepresentationAttributes? =
      kind == .video
      ? try VideoRepresentationAttributes(
        width: j["width"] as? Int ?? 0, height: j["height"] as? Int ?? 0,
        frameRate: Self.frameRate(j["frameRate"] as? String ?? j["frame_rate"] as? String),
        dynamicRange: Self.dynamicRange(j)) : nil
    let backups = (j["backupUrl"] as? [String] ?? j["backup_url"] as? [String] ?? []).compactMap(
      URL.init(string:)
    ).filter { BiliMediaCDNURLPolicy().allows($0) }
    return MediaRepresentation(
      id: j["id"] as? Int ?? 0, kind: kind, codecs: j["codecs"] as? String ?? "",
      mimeType: j["mimeType"] as? String ?? j["mime_type"] as? String ?? "video/mp4",
      bandwidth: j["bandwidth"] as? Int, videoAttributes: attrs, primaryURL: url,
      backupURLs: backups,
      segmentBase: SegmentBase(
        initialization: try range(seg["Initialization"] ?? seg["initialization"]),
        index: try range(seg["indexRange"] ?? seg["index_range"])))
  }
  static func frameRate(_ raw: String?) -> Double? {
    guard let raw else { return nil }
    let parts = raw.split(separator: "/").compactMap { Double($0) }
    if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
    return parts.count == 1 ? parts[0] : nil
  }
  static func dynamicRange(_ j: [String: Any]) -> VideoDynamicRange {
    let transfer = j["color_transfer"] as? Int ?? j["transfer_characteristics"] as? Int
    if transfer == 18 { return .hlg }
    if transfer == 16 || [125, 126].contains(j["id"] as? Int ?? 0) { return .pq }
    return .sdr
  }
  static func bestVideo(_ videos: [MediaRepresentation], quality: Int) -> MediaRepresentation? {
    let candidates = videos.filter { $0.id == quality }
    if quality == 127, let av1 = candidates.first(where: { $0.codecs.hasPrefix("av01") }) {
      return av1
    }
    // Prefer the system's efficient HEVC path; keep the original Dolby sample type intact.
    return candidates.first {
      ["hvc1", "hev1", "dvh1", "dvhe"].contains(String($0.codecs.prefix(4)))
    } ?? candidates.first { $0.codecs.hasPrefix("avc1") } ?? candidates.first
  }
  static func mixin(_ key: String) -> String {
    let table = [
      46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29,
      28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22,
      25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
    ]
    let a = Array(key)
    return String(table.compactMap { $0 < a.count ? a[$0] : nil }.prefix(32))
  }
  static func sign(
    _ query: [String: String], key: String, timestamp: Int = Int(Date().timeIntervalSince1970)
  ) -> [String: String] {
    var p = query.mapValues { $0.filter { !"!'()*".contains($0) } }
    p["wts"] = "\(timestamp)"
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let joined = p.sorted { $0.key < $1.key }.map {
      "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&")
    p["w_rid"] = Insecure.MD5.hash(data: Data((joined + key).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    return p
  }
}
