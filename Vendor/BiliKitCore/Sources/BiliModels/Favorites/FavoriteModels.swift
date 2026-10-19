import Foundation

/// 当前账户自己创建的一个收藏夹，由 BiliAPI 映射 `/x/v3/fav/folder/created/list-all` 的一行产生。
///
/// 只保存侧栏与夹内页面需要的元数据；接口没有封面。`attr` 的其余位不进入模型。
public struct FavoriteFolder: Identifiable, Sendable, Equatable {
    /// 收藏夹的 media_id（接口的 `id`），夹内读取用它。
    public let id: Int64
    public let title: String
    /// 夹内条目数（接口的 `media_count`）。
    public let mediaCount: Int
    /// 私密收藏夹（`attr` 的 bit0 为 1）。
    public let isPrivate: Bool
    /// 默认收藏夹（`attr` 的 bit1 为 0）；按标记识别，不靠在列表里的位置。
    public let isDefault: Bool

    public init(id: Int64, title: String, mediaCount: Int, isPrivate: Bool, isDefault: Bool) {
        self.id = id
        self.title = title
        self.mediaCount = mediaCount
        self.isPrivate = isPrivate
        self.isDefault = isDefault
    }
}

/// 收藏夹里的一条，由 BiliAPI 映射 `/x/v3/fav/resource/list` 的 `medias[]` 产生。
///
/// 可以播放的条目（`unavailability` 为 nil）是普通视频：`id` 就是它的 BVID，标题、作者、时长与收藏时间都齐全。
/// 不可用条目（合集、音频、番剧／影视、未知类型与已失效）可能缺这些字段，缺失时为 nil，由卡片省略或给占位；
/// 它们的 `id` 只作卡片身份，有合规 BVID 时取 BVID，否则由接口的类型与条目 ID 拼出，不能用来播放。
public struct FavoriteItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let coverURL: URL?
    public let owner: VideoOwner?
    public let durationSeconds: Int?
    /// 收藏时间（`fav_time`）。
    public let favoritedAt: Date?
    /// nil 表示可以进入播放。
    public let unavailability: LibraryItemUnavailability?

    public init(
        id: String,
        title: String?,
        coverURL: URL?,
        owner: VideoOwner?,
        durationSeconds: Int?,
        favoritedAt: Date?,
        unavailability: LibraryItemUnavailability? = nil
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.durationSeconds = durationSeconds
        self.favoritedAt = favoritedAt
        self.unavailability = unavailability
    }
}
