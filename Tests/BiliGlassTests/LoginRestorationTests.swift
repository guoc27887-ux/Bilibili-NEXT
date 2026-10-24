import Foundation
import Testing
@testable import BiliGlass

private final class LoginStatusProtocol: URLProtocol, @unchecked Sendable {
  private var work: DispatchWorkItem?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
    if cookie.contains("offline") || cookie.contains("timeout") {
      client?.urlProtocol(self, didFailWithError: URLError(cookie.contains("offline") ? .notConnectedToInternet : .timedOut))
      return
    }
    let body: [String: Any]
    if cookie.isEmpty || cookie.contains("expired") { body = ["code": -101] }
    else if cookie.contains("malformed") { body = ["code": 0, "data": [:]] }
    else if cookie.contains("rejected") { body = ["code": 0, "data": ["isLogin": false]] }
    else { body = ["code": 0, "data": ["isLogin": true, "mid": 1, "uname": "测试账号", "face": ""]] }
    let data = try! JSONSerialization.data(withJSONObject: body)
    let item = DispatchWorkItem { [self] in
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: cookie.contains("limited") ? 412 : 200,
        httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
    work = item
    DispatchQueue.global().asyncAfter(deadline: .now() + (cookie.isEmpty || cookie.contains("delayed") ? 0.15 : 0), execute: item)
  }
  override func stopLoading() { work?.cancel() }
}

@MainActor struct LoginRestorationTests {
  private func api(_ mode: String) -> API {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LoginStatusProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: configuration),
      credentialAccount: "test-login-restoration-\(UUID())")
    api.cookies = ["SESSDATA": mode, "DedeUserID": "1", "bili_jct": "fixture"]
    return api
  }

  @Test(arguments: ["offline", "timeout", "limited", "malformed"])
  func connectionAndResponseFailuresPreserveSavedAccount(_ mode: String) async throws {
    let api = api(mode); defer { api.session.invalidateAndCancel() }
    let previous = Account(name: "上次的昵称", mid: 1, face: "saved-avatar")
    let result = try await LoginRestoration.check(api: api, previous: previous)
    #expect(result.account?.name == previous.name)
    #expect(result.account?.face == previous.face)
    #expect(result.shouldRetry && result.message != nil)
    #expect(api.signedIn)
    let cold = try await LoginRestoration.check(api: api, previous: nil)
    #expect(cold.account?.mid == 1)
  }

  @Test func successfulRetryReplacesProvisionalProfile() async throws {
    let api = api("offline"); defer { api.session.invalidateAndCancel() }
    let failed = try await LoginRestoration.check(api: api, previous: nil)
    api.cookies["SESSDATA"] = "valid"
    let restored = try await LoginRestoration.check(api: api, previous: failed.account)
    #expect(restored.account?.name == "测试账号")
    #expect(!restored.shouldRetry && restored.message == nil)
  }

  @Test(arguments: ["expired", "rejected"])
  func explicitRejectionRequiresLoginWithoutErasingCredentials(_ mode: String) async throws {
    let api = api(mode); defer { api.session.invalidateAndCancel() }
    let result = try await LoginRestoration.check(api: api, previous: nil)
    #expect(result.account == nil && !result.shouldRetry)
    #expect(result.message == "登录已失效，请重新登录。")
    #expect(api.signedIn)
  }

  @Test func noSavedLoginRemainsGuest() async throws {
    let api = api("valid"); defer { api.session.invalidateAndCancel() }
    api.cookies = [:]
    let result = try await LoginRestoration.check(api: api, previous: nil)
    #expect(result.account == nil && !result.shouldRetry && result.message == nil)
  }

  @Test func oldProfileCannotBeAssignedToAnotherAccount() async throws {
    let api = api("offline"); defer { api.session.invalidateAndCancel() }
    let result = try await LoginRestoration.check(api: api, previous: Account(name: "其他账号", mid: 2, face: ""))
    #expect(result.account?.mid == 1 && result.account?.name == "已登录")
  }

  @Test func logoutDuringValidationCannotRestoreAccount() async throws {
    let api = api("delayed"); defer { api.session.invalidateAndCancel() }
    let pending = Task { try await LoginRestoration.check(api: api, previous: nil) }
    try await Task.sleep(for: .milliseconds(20))
    api.logout()
    do { _ = try await pending.value; Issue.record("Old account restored after logout") }
    catch { #expect(error is CancellationError) }
    #expect(!api.signedIn)
  }

  @Test func guestRequestCannotMarkRestoredLoginExpired() async throws {
    let api = api("valid"); defer { api.session.invalidateAndCancel() }
    let saved = try JSONEncoder().encode(StoredLogin(cookies: api.cookies, appCoinAuthorization: nil))
    api.cookies = [:]
    let guest = Task { try await api.nav() }
    try await Task.sleep(for: .milliseconds(30))
    await api.restoreCredentials { name in name.hasSuffix(".legacy-authorization") ? nil : saved }
    let restored = try await LoginRestoration.check(api: api, previous: nil)
    #expect(restored.account?.mid == 1)
    #expect(restored.message == nil)
    do { _ = try await guest.value; Issue.record("Guest request survived credential restoration") }
    catch { #expect(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
  }
}
