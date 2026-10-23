import Foundation

/// API picture URLs may be HTTP or scheme-relative; normalize before validation.
enum BiliImageURL {
  static func parse(_ raw: String) -> URL? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var parts = URLComponents(string: value.hasPrefix("//") ? "https:" + value : value),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
      parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
      let host = parts.host?.lowercased(),
      host == "hdslb.com" || host.hasSuffix(".hdslb.com") || host == "biliimg.com"
        || host.hasSuffix(".biliimg.com")
    else { return nil }
    parts.scheme = "https"
    return parts.url
  }
}
