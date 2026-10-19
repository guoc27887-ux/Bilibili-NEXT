import BiliModels

/// 已经确认的账户会话事实；认证操作进行中不会把原有事实降级为未登录。
public enum AccountSessionState: Sendable, Equatable {
    case unresolved
    case signedOut
    case signedIn(AccountIdentity?)
}

/// Feature 可观察的非秘密认证状态；不携带二维码 payload、Cookie 或 Keychain 细节。
public enum AuthenticationState: Sendable, Equatable {
    case signedOut
    case restoring
    case requestingQRCode
    case awaitingScan
    case awaitingConfirmation
    case finalizing
    case signedIn(AccountIdentity?)
    case signingOut
    case expired
    case failed(AuthenticationFailure)
}

/// 认证操作失败的非秘密分类，认证界面据此选择文案。
///
/// 由 BiliAuth 的 `BiliAuthenticationService` 把 QR 登录与凭据复核的内部错误映射而来；不携带服务端
/// message 或 payload，见 SECURITY-MODEL §2。
public enum AuthenticationFailure: Error, Sendable, Equatable {
    /// 网络或 HTTP 失败；复核被取消或远端校验不可用时凭据状态未知，也归为这一类，保持可重试。
    case network
    /// 登录服务拒绝本次请求，或扫码确认后会话校验判定未登录。
    case serviceUnavailable
    /// 协议返回无法安全处理的数据，或凭据复核遇到意外的授权错误；失败关闭。
    case invalidResponse
    /// Keychain 读写不可用；登出时删除凭据失败也报告这一类，不发布未登录。
    case credentialUnavailable
}

/// 认证 adapter 暴露给 Presentation 的用户意图边界。
///
/// 实现是 BiliAuth 的 `BiliAuthenticationService`，调用方只有 `AuthenticationViewModel`；其他
/// Feature 发现凭据失效时经 `AccountRevalidationParticipant` 让窗口复核，不直接调用这里。
/// 每次调用返回 adapter 的当前安全投影：被后续操作取代的结果由实现内部按 generation 丢弃，
/// 此时返回的是当前状态而不是本次操作的结果。调用方仍负责 UI Task 的取消与迟到结果隔离。
public protocol AuthenticationServicing: Sendable {
    func restore() async -> AuthenticationState
    /// 另一窗口已推进全局会话变化后复核凭据；实现不得再次传播会话失效，避免同一变化重复广播。
    func restoreAfterExternalSessionChange() async -> AuthenticationState
    func requestQRCode() async -> AuthenticationState
    func pollOnce() async -> AuthenticationState
    func finalizeLogin() async -> AuthenticationState
    func cancelLogin() async -> AuthenticationState
    func logout() async -> AuthenticationState
}

/// 账户会话失效时，由认证 owner 通知仍可能持有已授权在途请求或排队写入的会话。
///
/// `BiliAuthenticationService` 在登出、以及复核确认原有凭据已失效时调用，经 App 的
/// `AccountSessionCoordinator` 扇出到各窗口的 `BiliAPIClient`、测速 client 与
/// `SerializedWatchProgressRepository`。实现必须推进自己的 epoch 或 generation 并取消旧会话的请求，
/// 使其结果不再写回；全部调用返回后认证服务才发布新状态，见 SECURITY-MODEL §2。
public protocol AuthenticatedSessionInvalidating: Sendable {
    func invalidateAuthenticatedSession() async
}
