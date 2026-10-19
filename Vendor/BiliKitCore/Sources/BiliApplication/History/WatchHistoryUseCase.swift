import BiliModels

/// 把远端分页适配为可显示的历史页，并有界跳过映射后为空的页面。
///
/// 空页 continuation 必须前进；达到跳过上限时返回令牌供用户显式继续，避免后台无界扫描。
public struct WatchHistoryUseCase: Sendable {
    /// 每次向远端请求的条数；`VideoListRetention.maximumLoadedPages` 按每页 20 条估算页数余量，
    /// 调整时一并核对。
    private static let pageSize = 20
    /// 一次 `load` 最多自动跳过的空页数，达到后返回空页与 continuation 由用户显式继续；
    /// 调大会在一次加载里连续请求更多页，调小会更早要求用户继续。
    private static let maximumEmptyPagesToSkip = 3

    private let repository: any WatchHistoryRepository

    public init(repository: any WatchHistoryRepository) {
        self.repository = repository
    }

    public func load(
        after continuation: WatchHistoryContinuation? = nil
    ) async throws -> WatchHistoryPage {
        var requestContinuation = continuation
        var skippedEmptyPages = 0

        while true {
            try Task.checkCancellation()
            let page = try await repository.watchHistory(
                after: requestContinuation,
                pageSize: Self.pageSize
            )
            if let nextContinuation = page.continuation,
                nextContinuation == requestContinuation
            {
                throw ContentApplicationError.invalidResponse
            }
            guard page.items.isEmpty,
                let nextContinuation = page.continuation
            else {
                return page
            }
            guard skippedEmptyPages < Self.maximumEmptyPagesToSkip else {
                return page
            }
            skippedEmptyPages += 1
            requestContinuation = nextContinuation
        }
    }
}
