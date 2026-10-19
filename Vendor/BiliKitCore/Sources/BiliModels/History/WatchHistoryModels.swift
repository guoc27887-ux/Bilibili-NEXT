import Foundation

/// 观看这条历史时所用的设备。
public enum WatchHistoryDevice: Sendable, Equatable {
    case phone
    case pad
    case web
    case tv
}

/// 观看历史（`/x/web-interface/history/cursor`）里的一条视频，由 BiliAPI 的
/// `WatchHistoryItemPayload` 映射产生。
///
/// 只保留稿件类历史；`progressSeconds` 不超过时长，接口用负数表示已看完时取整段时长。
public struct WatchHistoryItem: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let progressSeconds: Int
    public let durationSeconds: Int
    public let viewedAt: Date
    /// 接口未给出或无法识别时为 nil。
    public let device: WatchHistoryDevice?

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        owner: VideoOwner,
        progressSeconds: Int,
        durationSeconds: Int,
        viewedAt: Date,
        device: WatchHistoryDevice? = nil
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.progressSeconds = progressSeconds
        self.durationSeconds = durationSeconds
        self.viewedAt = viewedAt
        self.device = device
    }
}
