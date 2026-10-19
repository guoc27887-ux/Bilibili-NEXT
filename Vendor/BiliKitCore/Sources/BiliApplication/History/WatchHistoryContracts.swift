import BiliModels

/// API adapter 生成并消费的不透明分页令牌。
///
/// Presentation 与 Use Case 只能保存和回传，
/// 不知道远端 cursor 的字段或编码。
public struct WatchHistoryContinuation: Sendable, Equatable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// 观看历史的一页：条目与下一页 continuation，continuation 为 nil 表示远端没有更多。
public struct WatchHistoryPage: Sendable, Equatable {
    public let items: [WatchHistoryItem]
    public let continuation: WatchHistoryContinuation?

    public init(
        items: [WatchHistoryItem],
        continuation: WatchHistoryContinuation?
    ) {
        self.items = items
        self.continuation = continuation
    }
}

/// 观看历史的认证数据 port；Presentation 只能回传 adapter 生成的不透明 continuation。
///
/// 实现是 BiliAPI 的 `BiliWatchHistoryRepository`，只经 `WatchHistoryUseCase` 调用；只按账户读取，
/// 本地无凭据时失败，不退回匿名请求。Endpoint、凭据与远端错误映射属于具体 adapter，不进入
/// Application；失败统一抛出 `ContentApplicationError`，取消原样传播。
public protocol WatchHistoryRepository: Sendable {
    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage
}
