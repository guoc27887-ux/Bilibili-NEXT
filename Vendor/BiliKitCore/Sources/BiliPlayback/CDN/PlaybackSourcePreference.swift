import BiliModels
import Foundation

/// 服务端候选地址的 CDN 类别。
public enum PlaybackSourceCategory: String, Sendable, Equatable, CaseIterable {
    case akamai
    case bilivideo
}

/// 可固定选择的 bilivideo 镜像；只替换服务端原始 bilivideo 地址的 host，保留签名（见
/// docs/ARCHITECTURE.md「播放线路偏好与测速」）。
public enum BilivideoRoute: String, Sendable, Equatable, Hashable, CaseIterable {
    case tencentOverseas
    case alibabaOverseas
    case alibabaMainland
    case alibabaMainlandB
    case alibabaMainlandO1
    case tencentMainland
    case tencentMainlandB
    case tencentMainlandO1
    case huaweiMainland
    case huaweiMainlandB
    case huaweiMainlandO1
    case huawei08C
    case huawei08H
    case huawei08CT
    case huaweiAll
    case tencentAll
    case baiduMainland
    case bda2Mainland

    public var displayName: String {
        switch self {
        case .tencentOverseas: "腾讯海外 COSOV"
        case .alibabaOverseas: "阿里海外 ALIOV"
        case .alibabaMainland: "阿里 ALI"
        case .alibabaMainlandB: "阿里 ALIB"
        case .alibabaMainlandO1: "阿里 ALIO1"
        case .tencentMainland: "腾讯 COS"
        case .tencentMainlandB: "腾讯 COSB"
        case .tencentMainlandO1: "腾讯 COSO1"
        case .huaweiMainland: "华为 HW"
        case .huaweiMainlandB: "华为 HWB"
        case .huaweiMainlandO1: "华为 HWO1"
        case .huawei08C: "华为 08C"
        case .huawei08H: "华为 08H"
        case .huawei08CT: "华为 08CT"
        case .huaweiAll: "华为 TF 全域"
        case .tencentAll: "腾讯 TX 全域"
        case .baiduMainland: "百度 BOS"
        case .bda2Mainland: "UPCDN BDA2（大陆）"
        }
    }

    public var host: String {
        switch self {
        case .tencentOverseas: "upos-sz-mirrorcosov.bilivideo.com"
        case .alibabaOverseas: "upos-sz-mirroraliov.bilivideo.com"
        case .alibabaMainland: "upos-sz-mirrorali.bilivideo.com"
        case .alibabaMainlandB: "upos-sz-mirroralib.bilivideo.com"
        case .alibabaMainlandO1: "upos-sz-mirroralio1.bilivideo.com"
        case .tencentMainland: "upos-sz-mirrorcos.bilivideo.com"
        case .tencentMainlandB: "upos-sz-mirrorcosb.bilivideo.com"
        case .tencentMainlandO1: "upos-sz-mirrorcoso1.bilivideo.com"
        case .huaweiMainland: "upos-sz-mirrorhw.bilivideo.com"
        case .huaweiMainlandB: "upos-sz-mirrorhwb.bilivideo.com"
        case .huaweiMainlandO1: "upos-sz-mirrorhwo1.bilivideo.com"
        case .huawei08C: "upos-sz-mirror08c.bilivideo.com"
        case .huawei08H: "upos-sz-mirror08h.bilivideo.com"
        case .huawei08CT: "upos-sz-mirror08ct.bilivideo.com"
        case .huaweiAll: "upos-tf-all-hw.bilivideo.com"
        case .tencentAll: "upos-tf-all-tx.bilivideo.com"
        case .baiduMainland: "upos-sz-mirrorbos.bilivideo.com"
        case .bda2Mainland: "upos-sz-upcdnbda2.bilivideo.com"
        }
    }

    /// 保留服务端 URL 的 scheme、path、query 与签名字节，只替换已核实的 bilivideo authority。
    public func replacingHost(in template: URL) -> URL? {
        guard template.scheme?.lowercased() == "https",
            template.user == nil,
            template.password == nil,
            PlaybackSourceClassifier.category(for: template) == .bilivideo
        else { return nil }
        let original = template.absoluteString
        guard let separator = original.range(of: "://") else { return nil }
        let authorityStart = separator.upperBound
        let suffixStart =
            original[authorityStart...].firstIndex {
                $0 == "/" || $0 == "?" || $0 == "#"
            } ?? original.endIndex
        return URL(string: "https://\(host)\(original[suffixStart...])")
    }
}

/// Settings 里的播放线路偏好；每次新 load 只读一次，只调整视频候选：重排顺序，或在最前插入换了
/// host 的镜像地址。
public enum PlaybackSourcePreference: Sendable, Equatable {
    case serverDefault
    case category(PlaybackSourceCategory)
    case experimentalBilivideoRoute(BilivideoRoute)
}

/// 按 host 把候选地址归入 Akamai 或 bilivideo，只用于排序与测速选址。
///
/// 这不是来源校验：地址是否允许由 `BiliMediaCDNURLPolicy` 判定，见 SECURITY-MODEL §4。
public enum PlaybackSourceClassifier {
    public static func category(for url: URL) -> PlaybackSourceCategory? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "akamaized.net" || host.hasSuffix(".akamaized.net")
            || host == "akamaihd.net" || host.hasSuffix(".akamaihd.net")
        {
            return .akamai
        }
        if host == "bilivideo.com" || host.hasSuffix(".bilivideo.com")
            || host == "bilivideo.cn" || host.hasSuffix(".bilivideo.cn")
        {
            return .bilivideo
        }
        return nil
    }
}

/// 按偏好重排一个视频 representation 的候选地址。
///
/// 类别偏好把该类地址排前；实验镜像把换了 host 的地址放在最前，其余保持原序。
/// 找不到对应地址时保持服务端顺序，音频 representation 不动。
public enum PlaybackSourceOrdering {
    public static func applying(
        _ preference: PlaybackSourcePreference,
        to representation: MediaRepresentation
    ) -> MediaRepresentation {
        guard representation.kind == .video else { return representation }
        let original = representation.urlCandidates
        let reordered: [URL]
        switch preference {
        case .serverDefault:
            return representation
        case .category(let category):
            guard
                original.contains(where: {
                    PlaybackSourceClassifier.category(for: $0) == category
                })
            else { return representation }
            reordered =
                original.filter {
                    PlaybackSourceClassifier.category(for: $0) == category
                }
                + original.filter {
                    PlaybackSourceClassifier.category(for: $0) != category
                }
        case .experimentalBilivideoRoute(let route):
            guard
                let template = original.first(where: {
                    PlaybackSourceClassifier.category(for: $0) == .bilivideo
                }), let routed = route.replacingHost(in: template)
            else { return representation }
            reordered = [routed] + original.filter { $0 != routed }
        }
        guard reordered != original, let primary = reordered.first else {
            return representation
        }
        return MediaRepresentation(
            id: representation.id,
            kind: representation.kind,
            codecs: representation.codecs,
            mimeType: representation.mimeType,
            bandwidth: representation.bandwidth,
            videoAttributes: representation.videoAttributes,
            primaryURL: primary,
            backupURLs: Array(reordered.dropFirst()),
            segmentBase: representation.segmentBase
        )
    }
}
