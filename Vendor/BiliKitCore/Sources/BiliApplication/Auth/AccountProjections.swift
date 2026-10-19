import BiliModels
import Foundation

/// 窗口 owner 可用于隔离个性化内存的最小非秘密会话 identity。
///
/// 由窗口的账户会话状态（`AccountSessionState`）得出；App 据此判断账户是否切换。
public enum AccountSessionScope: Sendable, Equatable {
    case unresolved
    case signedOut
    case signedIn(accountID: Int64?)

    /// 两侧都已解析且不相同才算账户切换；从 `unresolved` 解析出结果不算切换。
    public static func isResolvedChange(from previous: Self, to current: Self) -> Bool {
        previous != .unresolved && current != .unresolved && previous != current
    }
}

/// 供产品界面使用的诚实账户呈现状态；不可用与确定登出保持区分。
///
/// 由窗口的账户会话状态与恢复结果得出，只按账户读取的来源据此渲染登录门槛；不携带 Cookie 或失败细节。
public enum AccountPresentationState: Sendable, Equatable {
    case resolving
    case unavailable
    case signedOut
    case signedIn(AccountIdentity?)

    public var displayName: String? {
        guard case .signedIn(let identity) = self else { return nil }
        return identity?.displayName
    }

    public var avatarURL: URL? {
        guard case .signedIn(let identity) = self else { return nil }
        return identity?.avatarURL
    }
}
