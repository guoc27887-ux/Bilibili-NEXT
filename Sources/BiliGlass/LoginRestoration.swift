import Foundation

/// A failed connection does not tell us whether the saved login has expired.
@MainActor struct LoginRestoration {
  let account: Account?
  let message: String?
  let shouldRetry: Bool

  static func localAccount(api: API, previous: Account?) -> Account? {
    guard api.signedIn, let raw = api.cookies["DedeUserID"], let mid = Int(raw), mid > 0 else {
      return nil
    }
    return previous?.mid == mid ? previous : Account(name: "已登录", mid: mid, face: "")
  }

  @MainActor static func check(api: API, previous: Account?) async throws -> Self {
    let generation = api.authenticationGeneration
    let saved = localAccount(api: api, previous: previous)
    guard api.signedIn else { return Self(account: nil, message: nil, shouldRetry: false) }
    do {
      let account = try await api.nav()
      try Task.checkCancellation()
      guard generation == api.authenticationGeneration else { throw CancellationError() }
      return Self(account: account,
        message: account == nil ? "登录已失效，请重新登录。" : nil, shouldRetry: false)
    } catch {
      try Task.checkCancellation()
      guard generation == api.authenticationGeneration, !(error is CancellationError) else {
        throw CancellationError()
      }
      return Self(account: saved, message: "暂时无法确认登录状态，已保留本机登录信息。", shouldRetry: true)
    }
  }
}
