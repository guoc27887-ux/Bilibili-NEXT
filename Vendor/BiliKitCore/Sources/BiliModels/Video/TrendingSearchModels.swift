import Foundation

/// B 站热搜中的一个词：`keyword` 用于发起搜索，`displayName` 用于展示。
///
/// `iconURL` 只在通过 B 站图床来源规则后才存在；没有图标时只展示文字。
public struct TrendingSearchKeyword: Sendable, Equatable, Hashable {
    public let keyword: String
    public let displayName: String
    public let iconURL: URL?

    public init(keyword: String, displayName: String, iconURL: URL?) {
        self.keyword = keyword
        self.displayName = displayName
        self.iconURL = iconURL
    }
}
