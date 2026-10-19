import Darwin
import Foundation

/// 远端 URL 的形状基线：HTTPS、无 userinfo 与 fragment、端口缺省或 443，拒绝 IP literal 与
/// 本地域名后缀。
///
/// 它不解析 DNS，因而不能证明公共域名不会指向私网；媒体、字幕、图片等调用方仍需叠加用途专属
/// 主机规则（见 SECURITY-MODEL §4）。
public struct PublicHTTPSURLPolicy: Sendable {
    public init() {}

    public func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
            url.user == nil,
            url.password == nil,
            url.fragment == nil,
            url.port == nil || url.port == 443,
            let rawHost = url.host?.lowercased(),
            !rawHost.isEmpty
        else {
            return false
        }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty,
            !host.hasSuffix("."),
            host != "localhost",
            !host.hasSuffix(".localhost"),
            !host.hasSuffix(".local"),
            !host.hasSuffix(".internal"),
            host != "home.arpa",
            !host.hasSuffix(".home.arpa"),
            !Self.isIPAddress(host)
        else {
            return false
        }
        return true
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") || looksLikeLegacyIPv4Literal(host) {
            return true
        }

        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }

        var ipv6 = in6_addr()
        return host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }

    private static func looksLikeLegacyIPv4Literal(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            if label.allSatisfy(\.isNumber) {
                return true
            }
            guard label.lowercased().hasPrefix("0x") else { return false }
            return label.dropFirst(2).allSatisfy(\.isHexDigit)
        }
    }
}
