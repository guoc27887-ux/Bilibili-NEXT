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
