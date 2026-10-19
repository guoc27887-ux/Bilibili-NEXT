import BiliModels

/// 收藏夹内的排序：最近收藏（默认）、最多播放、最近投稿。
///
/// BiliAPI 把它映射为 `order`（`mtime`／`view`／`pubtime`）。
public enum FavoriteFolderOrder: Sendable, Hashable, CaseIterable, Identifiable {
    case recentlyFavorited
    case mostPlayed
    case recentlyPublished

    public var id: Self { self }
}

/// 一次收藏夹内的读取：收藏夹、排序、关键词与从 1 开始的页码。
///
/// 关键词在初始化时按 `SearchText` 规范化，空串表示不按关键词过滤（只搜当前收藏夹，由服务端匹配）。
public struct FavoriteFolderRequest: Sendable, Hashable {
    public let folderID: Int64
    public let order: FavoriteFolderOrder
    public let keyword: String
    public let page: Int

    public init(
        folderID: Int64,
        order: FavoriteFolderOrder = .recentlyFavorited,
        keyword: String = "",
        page: Int = 1
    ) {
        self.folderID = folderID
        self.order = order
        self.keyword = SearchText.normalized(keyword)
        self.page = page
    }

    /// 收藏夹 ID 与页码为正，关键词不超过 `SearchText` 的长度上限。
    public var isValid: Bool {
        folderID > 0 && page > 0 && SearchText.isWithinLimit(keyword)
    }
}

/// 收藏夹内的一页：条目、页码、每页条数、当前条件下的总条数与是否还有下一页。
///
/// 按页整体替换，由 `PageReplacementPaging` 算总页数。`totalCount` 为 nil 表示这一页落在末尾之后、接口没有给出可信的
/// 总数（越界页的 `media_count` 为 0），翻页状态据此保留上一次的总数；有关键词时总数是过滤后的条数。页内条数不足甚至
/// 为 0 不代表结束，是否还有下一页以接口的 `has_more` 为准。
public struct FavoriteFolderPage: Sendable, Equatable {
    public let items: [FavoriteItem]
    public let pageNumber: Int
    public let pageSize: Int
    public let totalCount: Int?
    public let hasMore: Bool

    public init(
        items: [FavoriteItem],
        pageNumber: Int,
        pageSize: Int,
        totalCount: Int?,
        hasMore: Bool
    ) {
        self.items = items
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.totalCount = totalCount
        self.hasMore = hasMore
    }
}

/// 收藏夹的认证读取 port：自己创建的收藏夹列表与夹内的一页。
///
/// 实现是 BiliAPI 的 `BiliFavoritesRepository`，只经 `FavoritesUseCase` 调用；只按账户读取，本地无凭据时失败，不退回
/// 匿名请求。列表的 `ownerID` 由调用方从窗口账户范围给出，adapter 不自己取账户。失败统一抛出
/// `ContentApplicationError`：收藏夹不存在（被删除或不属于当前账户）为 `contentUnavailable`；取消原样传播。
public protocol FavoritesRepository: Sendable {
    /// 按接口返回顺序；接口没有给出列表（`data` 为 null）时为空数组，由 `FavoritesUseCase` 判断是否可疑。
    func favoriteFolders(ownerID: Int64) async throws -> [FavoriteFolder]
    func favoriteFolderPage(request: FavoriteFolderRequest) async throws -> FavoriteFolderPage
}

/// 读取收藏夹列表与夹内的一页，并校验结果。
public struct FavoritesUseCase: Sendable {
    private let repository: any FavoritesRepository

    public init(repository: any FavoritesRepository) {
        self.repository = repository
    }

    /// `ownerID` 不是正数时不发请求。
    ///
    /// 已登录用户自己视角下必有默认收藏夹。Cookie 失效时接口不报 -101，而是悄悄退化成访客视角（列表为空或只剩公开
    /// 夹），所以没有默认收藏夹按凭据失效报告，交给窗口复核账户；复核后仍然如此时由调用方的复核规则停止自动重试。
    /// 这只能发现一部分失效：默认收藏夹公开时访客视角仍会返回它，失效后列表只是少了私密收藏夹，这时要靠其他账户读取
    /// 返回 -101 触发复核。见 SECURITY-MODEL §3、§9。
    public func folders(ownerID: Int64) async throws -> [FavoriteFolder] {
        guard ownerID > 0 else { throw ContentApplicationError.invalidRequest }
        let folders = try await repository.favoriteFolders(ownerID: ownerID)
        guard folders.contains(where: \.isDefault) else {
            throw ContentApplicationError.authenticationInvalid
        }
        return folders
    }

    /// 请求不合法时不发请求；响应的页码不是所请求的页时按无效响应失败。
    ///
    /// 同页内重复的条目只保留第一条：网格以条目 ID 为身份。
    public func page(_ request: FavoriteFolderRequest) async throws -> FavoriteFolderPage {
        guard request.isValid else { throw ContentApplicationError.invalidRequest }
        let result = try await repository.favoriteFolderPage(request: request)
        guard result.pageNumber == request.page else {
            throw ContentApplicationError.invalidResponse
        }
        return FavoriteFolderPage(
            items: result.items.uniquedByBVID(\.id),
            pageNumber: result.pageNumber,
            pageSize: result.pageSize,
            totalCount: result.totalCount,
            hasMore: result.hasMore
        )
    }
}
