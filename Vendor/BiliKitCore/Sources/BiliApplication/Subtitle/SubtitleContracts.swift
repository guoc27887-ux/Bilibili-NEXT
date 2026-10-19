import BiliModels

/// 字幕读取的应用级错误，由 BiliAPI 的 `BiliSubtitleRepository` 从 `BiliAPIError.Failure` 映射。
///
/// 认证与内容页同一四态：无凭据、凭据失效（唯一触发账户复核）、本地凭据读不到、风控。
public enum SubtitleApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    case authenticationRequired
    case authenticationInvalid
    case authenticationUnavailable
    case requestRestricted
    case transportFailure
    case invalidResponse
    case unavailable
}

extension SubtitleApplicationError {
    /// 只有凭据失效需要窗口复核账户会话；`SubtitleUseCase` 据此发出复核信号。
    public var requiresAccountRevalidation: Bool {
        self == .authenticationInvalid
    }
}

/// 字幕目录与正文的 identity-scoped port。
///
/// 实现是 BiliAPI 的 `BiliSubtitleRepository`，只经 `SubtitleUseCase` 调用（BiliPlayback
/// 的播放引擎与字幕来源）。失败抛出 `SubtitleApplicationError`，取消原样传播为
/// `CancellationError`；目录只按账户读取，正文从不携带凭据，见 SECURITY-MODEL §3。
///
/// `reset` 是 adapter 清除当前身份 URL 映射的生命周期操作，不是一般缓存清理。
public protocol SubtitleRepository: Sendable {
    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack]

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue]

    func reset(for identity: PlaybackItemIdentity) async
}

/// 在 adapter 前验证字幕 identity/track 输入，同时保持取消原样传播。
public struct SubtitleUseCase: Sendable {
    private let repository: any SubtitleRepository
    private let reportAuthenticationInvalidation: @Sendable () -> Void

    /// `reportAuthenticationInvalidation` 在字幕目录发现凭据失效时调用，与弹幕会话的凭据失效通知
    /// 同一契约：字幕失败不影响播放，播放侧只把目录当作空，复核信号必须在这里发出。
    public init(
        repository: any SubtitleRepository,
        reportAuthenticationInvalidation: @escaping @Sendable () -> Void
    ) {
        self.repository = repository
        self.reportAuthenticationInvalidation = reportAuthenticationInvalidation
    }

    public func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        guard !identity.bvid.isEmpty, identity.cid > 0 else {
            throw SubtitleApplicationError.invalidRequest
        }
        do {
            return try await repository.tracks(for: identity)
        } catch let error as SubtitleApplicationError where error.requiresAccountRevalidation {
            reportAuthenticationInvalidation()
            throw error
        }
    }

    public func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        guard !trackID.isEmpty, !identity.bvid.isEmpty, identity.cid > 0 else {
            throw SubtitleApplicationError.invalidRequest
        }
        return try await repository.cues(
            for: trackID,
            identity: identity
        )
    }

    public func reset(for identity: PlaybackItemIdentity) async {
        await repository.reset(for: identity)
    }
}
