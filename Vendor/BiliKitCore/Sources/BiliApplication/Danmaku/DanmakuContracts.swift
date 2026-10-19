import BiliModels

/// 弹幕分段读取的应用级错误。
///
/// 弹幕失败只让该分段静默失败，会话不再请求它，因此没有“需要登录”“本地凭据读不到”等独立状态，它们由
/// adapter 归入 `unavailable`；只有凭据失效需要区分，用于触发账户复核。
public enum DanmakuApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    case authenticationInvalid
    case requestRestricted
    case transportFailure
    case invalidResponse
    case unavailable
}

extension DanmakuApplicationError {
    /// 只有凭据失效需要窗口复核账户会话；`DanmakuSession` 据此发出一次复核通知。
    public var requiresAccountRevalidation: Bool {
        self == .authenticationInvalid
    }
}

/// 弹幕分段读取 port，实现是 BiliAPI 的 `BiliDanmakuRepository`，只经 `DanmakuSegmentUseCase`
/// 调用。
///
/// 失败抛出 `DanmakuApplicationError`，取消原样传播为 `CancellationError`。被 HTTP 412
/// 拒绝时的一次重试在 API 客户端内完成，调用方不再叠加重试，见 SECURITY-MODEL §3。
public protocol DanmakuSegmentRepository: Sendable {
    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment
}

/// 验证弹幕分段请求边界，并拒绝 adapter 返回与请求 index 不一致的结果。
public struct DanmakuSegmentUseCase: Sendable {
    /// 分段序号上限：每段 360 秒，约合 1000 小时，远超任何稿件时长，只用来拒绝越界的序号；
    /// 调小会让超长视频后段请求不到弹幕。
    public static let maximumSegmentIndex = 10_000

    private let repository: any DanmakuSegmentRepository

    public init(repository: any DanmakuSegmentRepository) {
        self.repository = repository
    }

    public func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        guard (1...Self.maximumSegmentIndex).contains(index),
            !identity.bvid.isEmpty,
            identity.cid > 0
        else {
            throw DanmakuApplicationError.invalidRequest
        }
        let segment = try await repository.segment(index: index, for: identity)
        guard segment.index == index else {
            throw DanmakuApplicationError.invalidResponse
        }
        return segment
    }
}
