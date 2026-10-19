import BiliModels

/// 播放页一次准备所聚合的详情、分 P、选中分 P 与播放清单。
public struct VideoContext: Sendable, Equatable {
    public let detail: VideoDetail
    public let pages: [VideoPage]
    public let selectedPage: VideoPage
    public let playback: VideoPlayback
    public let resumePositionSeconds: Double?

    public var accessNotice: PlaybackAccessNotice? {
        guard detail.access.isUPowerExclusive == true else { return nil }
        let fullDuration = Int64(selectedPage.durationSeconds)
            .multipliedReportingOverflow(by: 1_000)
        if detail.access.isUPowerPreviewAvailable == true,
            case .progressive(let source) = playback.media,
            source.durationMilliseconds > 0,
            selectedPage.durationSeconds > 0,
            !fullDuration.overflow,
            source.durationMilliseconds < fullDuration.partialValue
        {
            return .upowerPreview(
                previewDurationSeconds: Int(source.durationMilliseconds / 1_000),
                fullDurationSeconds: selectedPage.durationSeconds
            )
        }
        return .upowerExclusive
    }

    /// 当前分 P 里可以跳到的秒数上限（不含）；时长未知时为 nil。
    ///
    /// 充电试看只播放试看片段，上限是试看时长。评论时间戳是否显示为链接、链接起播与原地跳转都按它判断。
    public var seekableDurationSeconds: Int? {
        if case .upowerPreview(let previewDurationSeconds, _) = accessNotice {
            return previewDurationSeconds > 0 ? previewDurationSeconds : nil
        }
        return selectedPage.durationSeconds > 0 ? selectedPage.durationSeconds : nil
    }

    /// 秒数是否在可跳转范围内：不小于 0 且小于上限。
    public static func accepts(seconds: Int, seekableDurationSeconds: Int?) -> Bool {
        guard let seekableDurationSeconds else { return false }
        return seconds >= 0 && seconds < seekableDurationSeconds
    }

    public func acceptsSeek(toSeconds seconds: Int) -> Bool {
        Self.accepts(seconds: seconds, seekableDurationSeconds: seekableDurationSeconds)
    }

    /// 链接给的起播位置：只有能从指定位置起播的媒体（DASH）且在可跳转范围内时采用；progressive
    /// 总是从头播放，返回 nil。
    public func linkStartPosition(seconds: Int?) -> Double? {
        guard let seconds, case .dash = playback.media, acceptsSeek(toSeconds: seconds) else {
            return nil
        }
        return Double(seconds)
    }

    public init(
        detail: VideoDetail,
        pages: [VideoPage],
        selectedPage: VideoPage,
        playback: VideoPlayback,
        resumePositionSeconds: Double? = nil
    ) {
        self.detail = detail
        self.pages = pages
        self.selectedPage = selectedPage
        self.playback = playback
        self.resumePositionSeconds = resumePositionSeconds
    }
}

/// 充电专属稿件的访问提示，由 `VideoContext.accessNotice` 从详情权益与播放媒体推出。
///
/// `upowerPreview`：详情声明可试看，且拿到的 progressive 媒体短于分 P 全长，附带试看与完整时长；
/// `upowerExclusive`：充电专属稿件的其余情形（例如已能完整播放）。
public enum PlaybackAccessNotice: Sendable, Equatable {
    case upowerExclusive
    case upowerPreview(
        previewDurationSeconds: Int,
        fullDurationSeconds: Int
    )
}

/// 播放页准备视频的一次性用例：取得详情、选定分 P，再取得该分 P 的播放清单。
///
/// 分 P 只来自详情响应；缺失时视为无效响应，不再另行请求分 P。
///
/// 用例不拥有播放器，也不保留可变状态；任何一个阶段取消都会阻止后续播放请求或结果返回。
public struct VideoUseCase: Sendable {
    private let repository: any VideoRepository

    public init(repository: any VideoRepository) {
        self.repository = repository
    }

    /// 取得详情与选中分 P 的播放信息。
    ///
    /// `preferredCID` 是用户在应用内显式选中的分 P，不存在时报错；`preferredPageNumber` 来自外部链接
    /// （从 1 开始的分 P 序号），不可信：只在 `preferredCID` 缺省时参考，超出范围时按默认规则选择。
    public func prepareVideo(
        bvid: String,
        preferredCID: Int64? = nil,
        preferredPageNumber: Int? = nil
    ) async throws -> VideoContext {
        let resolvedDetail = try await repository.videoDetail(for: bvid)
        try Task.checkCancellation()
        guard resolvedDetail.bvid == bvid else {
            throw ContentApplicationError.invalidResponse
        }

        let sortedPages = resolvedDetail.pages.sorted(by: { $0.index < $1.index })
        guard let firstPage = sortedPages.first else {
            throw ContentApplicationError.invalidResponse
        }

        let requestedPage: VideoPage?
        if let preferredCID {
            guard let page = sortedPages.first(where: { $0.cid == preferredCID }) else {
                throw ContentApplicationError.invalidRequest
            }
            requestedPage = page
        } else {
            requestedPage = preferredPageNumber.flatMap { number in
                sortedPages.first(where: { $0.index == number })
            }
        }

        if let selectedPage = requestedPage {
            let playback = try await playback(
                detail: resolvedDetail,
                bvid: bvid,
                cid: selectedPage.cid
            )
            try Task.checkCancellation()
            // 应用内显式选中的分 P 从头播放；链接给的分 P 与普通打开一样续播该分 P 的上次位置。
            return VideoContext(
                detail: resolvedDetail,
                pages: sortedPages,
                selectedPage: selectedPage,
                playback: playback,
                resumePositionSeconds: preferredCID == nil
                    ? Self.resumePosition(metadata: playback.resumeMetadata, page: selectedPage)
                    : nil
            )
        }

        let provisionalPlayback = try await playback(
            detail: resolvedDetail,
            bvid: bvid,
            cid: firstPage.cid
        )
        try Task.checkCancellation()

        let selectedPage =
            provisionalPlayback.resumeMetadata.flatMap { metadata in
                sortedPages.first(where: { $0.cid == metadata.lastPlayedCID })
            } ?? firstPage
        let playback: VideoPlayback
        if selectedPage.cid == firstPage.cid {
            playback = provisionalPlayback
        } else {
            playback = try await self.playback(
                detail: resolvedDetail,
                bvid: bvid,
                cid: selectedPage.cid
            )
            try Task.checkCancellation()
        }

        return VideoContext(
            detail: resolvedDetail,
            pages: sortedPages,
            selectedPage: selectedPage,
            playback: playback,
            resumePositionSeconds: Self.resumePosition(
                metadata: provisionalPlayback.resumeMetadata,
                page: selectedPage
            )
        )
    }

    /// 取得合集 episode 的分 P；详情必须自带至少一个分 P。
    public func pagesForCollectionEpisode(bvid: String) async throws -> [VideoPage] {
        let detail = try await repository.videoDetail(for: bvid)
        try Task.checkCancellation()
        guard detail.bvid == bvid, !detail.pages.isEmpty else {
            throw ContentApplicationError.invalidResponse
        }
        return detail.pages.sorted(by: { $0.index < $1.index })
    }

    /// 复用同一视频已经取得的详情与分 P，只为指定 CID 重新取得播放清单。
    public func preparePage(
        in context: VideoContext,
        cid: Int64
    ) async throws -> VideoContext {
        guard let selectedPage = context.pages.first(where: { $0.cid == cid })
        else {
            throw ContentApplicationError.invalidRequest
        }
        let playback = try await playback(
            detail: context.detail,
            bvid: context.detail.bvid,
            cid: selectedPage.cid
        )
        try Task.checkCancellation()

        return VideoContext(
            detail: context.detail,
            pages: context.pages,
            selectedPage: selectedPage,
            playback: playback
        )
    }

    private func playback(
        detail: VideoDetail,
        bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        do {
            return try await repository.playback(for: bvid, cid: cid)
        } catch ContentApplicationError.serviceRejected(code: _)
            where detail.access.isUPowerExclusive == true
            && detail.access.isUPowerPlayable == false
            && detail.access.isUPowerPreviewAvailable == false
        {
            // 只有详情权益三态和 playurl 业务拒绝同时明确时才收窄为权益语义。
            throw ContentApplicationError.fullViewingEntitlementRequired
        }
    }

    static func resumePosition(
        metadata: PlaybackResumeMetadata?,
        page: VideoPage
    ) -> Double? {
        guard let metadata,
            metadata.lastPlayedCID == page.cid,
            page.durationSeconds > 0
        else { return nil }
        let seconds = Double(metadata.positionMilliseconds) / 1_000
        let latestUsefulPosition =
            Double(page.durationSeconds)
            - PlaybackResumePolicy.completedThresholdSeconds
        guard seconds > 0, seconds < latestUsefulPosition else { return nil }
        return seconds
    }
}
