import BiliModels

/// 读取 UP 主空间的一页投稿。
public struct UploaderVideoUseCase: Sendable {
    private let repository: any UploaderVideoRepository

    public init(repository: any UploaderVideoRepository) {
        self.repository = repository
    }

    /// 同页内重复的 BV 只保留第一条：列表以 BV 为 identity，重复会破坏 diffable 快照。
    public func page(
        ownerID: Int64,
        order: UploaderVideoOrder,
        page: Int
    ) async throws -> UploaderVideoPage {
        guard ownerID > 0, page > 0 else {
            throw ContentApplicationError.invalidRequest
        }
        let result = try await repository.uploaderVideos(
            ownerID: ownerID,
            order: order,
            page: page
        )
        try Task.checkCancellation()
        return UploaderVideoPage(
            videos: result.videos.uniquedByBVID(\.bvid),
            pageNumber: result.pageNumber,
            pageSize: result.pageSize,
            totalCount: result.totalCount
        )
    }
}
