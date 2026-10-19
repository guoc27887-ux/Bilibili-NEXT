import BiliModels
import Foundation

/// 读取搜索页展示的 B 站热搜：只保留能作为合法搜索词的条目，按关键词去重并限制条数。
public struct TrendingSearchUseCase: Sendable {
    /// 热搜最多显示的条数，同时作为请求的 `limit`；调大会让搜索起始页的热搜列表更长。
    public static let keywordLimit = 10

    private let repository: any TrendingSearchRepository

    public init(repository: any TrendingSearchRepository) {
        self.repository = repository
    }

    public func trendingKeywords() async throws -> [TrendingSearchKeyword] {
        let keywords = try await repository.trendingSearchKeywords(
            limit: Self.keywordLimit
        )
        try Task.checkCancellation()
        var seenQueries: Set<String> = []
        return Array(
            keywords.compactMap { keyword -> TrendingSearchKeyword? in
                let criteria = VideoSearchCriteria(query: keyword.keyword)
                guard criteria.isValid, seenQueries.insert(criteria.query).inserted
                else { return nil }
                let displayName = keyword.displayName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return TrendingSearchKeyword(
                    keyword: criteria.query,
                    displayName: displayName.isEmpty ? criteria.query : displayName,
                    iconURL: keyword.iconURL
                )
            }
            .prefix(Self.keywordLimit)
        )
    }
}
