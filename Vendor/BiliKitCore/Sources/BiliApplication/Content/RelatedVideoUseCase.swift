import BiliModels

/// 读取当前视频的相关推荐：去掉当前视频本身与重复的 BV，保持原顺序。
///
/// 由播放页的 `VideoViewModel` 调用，Task 与取消归它；空 BV 按无效请求拒绝。
public struct RelatedVideoUseCase: Sendable {
    private let repository: any RelatedVideoRepository

    public init(repository: any RelatedVideoRepository) {
        self.repository = repository
    }

    public func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        guard !bvid.isEmpty else {
            throw ContentApplicationError.invalidRequest
        }
        let videos = try await repository.relatedVideos(to: bvid)
        try Task.checkCancellation()
        return videos.filter { $0.bvid != bvid }.uniquedByBVID(\.bvid)
    }
}
