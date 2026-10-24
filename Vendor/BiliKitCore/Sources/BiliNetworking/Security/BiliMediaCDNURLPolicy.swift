import Foundation

/// Bili 媒体字节请求的用途专属 host allowlist。
///
/// 在 `PublicHTTPSURLPolicy` 之上只允许固定 CDN 域名及其子域与 `upos-*.akamaized.net`，
/// 不用 `*.bilibili.com` 后缀匹配。调用方在 DTO 映射时和实际建立媒体连接前都应检查；
/// Range client 本身只执行公共 HTTPS 基线。本策略不携带 Cookie，也不放宽重定向
/// （见 SECURITY-MODEL §4）。
public struct BiliMediaCDNURLPolicy: Sendable {
    private static let dedicatedDomainSuffixes = [
        "bilivideo.com",
        "bilivideo.cn",
        "szbdyd.com"
    ]

    private let publicHTTPSPolicy = PublicHTTPSURLPolicy()

    public init() {}

    /// Normalize API-provided HTTP and scheme-relative CDN URLs before validation.
    /// Transport remains HTTPS-only. Never rewrite a host, path, signed query or
    /// nonstandard port; callers can use a validated backup when a node is rejected.
    public func normalizedURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value.hasPrefix("//") ? "https:" + value : value)
        else { return nil }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
            if components.port == 80 { components.port = nil }
        }
        guard let url = components.url, allows(url) else { return nil }
        return url
    }

    public func allows(_ url: URL) -> Bool {
        guard publicHTTPSPolicy.allows(url),
            let host = url.host?.lowercased()
        else { return false }

        if Self.dedicatedDomainSuffixes.contains(where: {
            host == $0 || host.hasSuffix(".\($0)")
        }) {
            return true
        }
        return host.hasPrefix("upos-") && host.hasSuffix(".akamaized.net")
    }
}
