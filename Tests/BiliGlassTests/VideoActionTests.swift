import Foundation
import Testing
@testable import BiliGlass

private final class ActionProtocol: URLProtocol, @unchecked Sendable {
  struct Response { var json: String; var delay: Double = 0 }
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> Response)!
  private let lock = NSLock()
  private var stopped = false
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let result = try Self.handler(request)
      DispatchQueue.global().asyncAfter(deadline: .now() + result.delay) { [self] in
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
      }
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
private final class RequestLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [[String: String]] = []
  func append(_ value: [String: String]) { lock.lock(); storage.append(value); lock.unlock() }
  var values: [[String: String]] { lock.lock(); defer { lock.unlock() }; return storage }
}
private func form(_ request: URLRequest) -> [String: String] {
  var bytes = request.httpBody ?? Data()
  if let stream = request.httpBodyStream {
    stream.open(); defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      bytes.append(contentsOf: buffer.prefix(count))
    }
  }
  return Dictionary(uniqueKeysWithValues: String(decoding: bytes, as: UTF8.self).split(separator: "&").map {
    let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    return (String(parts[0]).removingPercentEncoding!, String(parts[1]).removingPercentEncoding!)
  })
}
private func relationResponse(_ request: URLRequest, liked: Bool = false, coins: Int = 0,
                              favorite: Bool = false) -> ActionProtocol.Response {
  #expect(request.url!.path == "/x/web-interface/archive/relation")
  return .init(json: "{\"code\":0,\"data\":{\"like\":\(liked),\"coin\":\(coins),\"favorite\":\(favorite)}}")
}

@Suite(.serialized) struct VideoActionTests {
  @MainActor private func api() -> API {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ActionProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config))
    api.cookies = ["SESSDATA": "fixture", "bili_jct": "fixture-csrf", "buvid3": "fixture-device"]
    return api
  }
  private func detail(_ aid: Int = 123) -> Detail {
    Detail(video: Video(bvid: "BV1xx411c7mD", title: "fixture", cover: "", author: "", duration: 100, views: 0),
      description: "", pages: [], aid: aid, counts: VideoCounts(["like": 10, "coin": 20, "favorite": 30, "share": 40]))
  }
  @Test @MainActor func readsScalarLikeAndCoinFavoriteStates() async throws {
    ActionProtocol.handler = { relationResponse($0, liked: true, coins: 2, favorite: true) }
    let result = try await api().videoRelation(123)
    #expect(result == VideoRelation(liked: true, coins: 2, favorited: true))
  }
  @Test @MainActor func relationRequestsUseTheVideoRefererAndPreserveFailureContext() async throws {
    ActionProtocol.handler = { request in
      #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.bilibili.com/video/BV1xx411c7mD/")
      return .init(json: #"{"code":-403,"message":"非法访问"}"#)
    }
    do {
      _ = try await api().videoRelation(123, bvid: "BV1xx411c7mD")
      Issue.record("A failed coin read must not become a zero balance")
    } catch let error as BiliError {
      #expect(error.code == -403)
      #expect(error.requiresVerification)
    }
  }
  @Test @MainActor func likeCanToggleBothWaysWithCSRFAndCounts() async {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      guard request.httpMethod == "POST" else { return relationResponse(request) }
      #expect(request.url?.path == "/x/web-interface/archive/like")
      #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("buvid3=fixture-device") == true)
      log.append(form(request)); return .init(json: #"{"code":0,"data":{}}"#)
    }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    await model.toggleLike(api: api)
    #expect(model.relation?.liked == true); #expect(model.counts.likes == 11)
    await model.toggleLike(api: api)
    #expect(model.relation?.liked == false); #expect(model.counts.likes == 10)
    #expect(log.values.map { $0["like"] } == ["1", "2"])
    #expect(log.values.allSatisfy { $0["csrf"] == "fixture-csrf" && $0["aid"] == "123" })
  }
  @Test @MainActor func duplicateTapSubmitsOnceAndStaleVideoCannotChangeCurrentState() async throws {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      if request.httpMethod == "POST" { log.append(form(request)); return .init(json: #"{"code":0,"data":{}}"#, delay: 0.15) }
      return relationResponse(request)
    }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    let first = Task { await model.toggleLike(api: api) }
    while model.operation == nil { await Task.yield() }
    await model.toggleLike(api: api)
    model.clear()
    await model.load(detail: detail(456), accountID: 1, api: api)
    await first.value
    #expect(log.values.count == 1)
    #expect(model.aid == 456); #expect(model.relation?.liked == false); #expect(model.counts.likes == 10)
    #expect(model.operation == nil)
  }
  @Test @MainActor func serverRejectionPreservesLikeAndExposesVerification() async {
    ActionProtocol.handler = { request in
      if request.httpMethod == "POST" { return .init(json: #"{"code":-352,"message":"需要验证"}"#) }
      return relationResponse(request)
    }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    await model.toggleLike(api: api)
    #expect(model.relation?.liked == false); #expect(model.counts.likes == 10)
    #expect(model.needsVerification); #expect(model.operation == nil)
  }
  @Test @MainActor func missingRelationDoesNotPretendUnliked() async {
    ActionProtocol.handler = { _ in .init(json: #"{"code":0,"data":{}}"#) }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    #expect(model.relation == nil); #expect(model.error != nil); #expect(!model.loading)
  }
  @Test @MainActor func coinLimitsBalanceAndAttachedLikeUseConfirmedResponse() async {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      if request.httpMethod == "POST" { log.append(form(request)); return .init(json: #"{"code":0,"data":{"like":false}}"#) }
      return relationResponse(request)
    }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    #expect(await model.sendCoins(amount: 2, limit: 1, balance: 10, alsoLike: false, api: api) == false)
    #expect(await model.sendCoins(amount: 2, limit: 2, balance: 1.5, alsoLike: false, api: api) == false)
    #expect(log.values.isEmpty)
    #expect(await model.sendCoins(amount: 2, limit: 2, balance: 10, alsoLike: true, api: api))
    #expect(model.relation?.coins == 2); #expect(model.counts.coins == 22)
    #expect(model.relation?.liked == false); #expect(model.counts.likes == 10)
    #expect(await model.sendCoins(amount: 1, limit: 2, balance: 10, alsoLike: false, api: api) == false)
    #expect(log.values.count == 1); #expect(log.values.first?["select_like"] == "1")
    #expect(log.values.first?["multiply"] == "2")
  }
  @Test @MainActor func videoWritesCarryVideoRefererAndOrigin() async throws {
    ActionProtocol.handler = { request in
      #expect(request.url?.path == "/x/web-interface/coin/add")
      #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.bilibili.com/video/BV1xx411c7mD/")
      #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.bilibili.com")
      #expect(form(request)["csrf"] == "fixture-csrf")
      return .init(json: #"{"code":0,"data":{"like":false}}"#)
    }
    _ = try await api().addVideoCoins(aid: 123, bvid: "BV1xx411c7mD", amount: 1, alsoLike: false)
  }
  @Test @MainActor func tripleIsOneRequestAndPartialResultsAreNotCalledComplete() async {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      if request.httpMethod != "POST" { return relationResponse(request) }
      #expect(request.url?.path == "/x/web-interface/archive/like/triple")
      log.append(form(request))
      return .init(json: #"{"code":0,"data":{"like":true,"coin":false,"fav":true,"multiply":0}}"#)
    }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    #expect(await model.sendTriple(api: api) == false)
    #expect(model.relation == VideoRelation(liked: true, coins: 0, favorited: true))
    #expect(model.counts.likes == 11); #expect(model.counts.coins == 20); #expect(model.counts.favorites == 31)
    #expect(model.error != nil); #expect(log.values.count == 1)
  }
  @Test @MainActor func tripleDuplicateTapAndTimeoutCannotSpendTwice() async {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      if request.httpMethod != "POST" { return relationResponse(request) }
      log.append(form(request)); throw URLError(.timedOut)
    }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    #expect(await model.sendTriple(api: api) == false)
    #expect(await model.sendTriple(api: api) == false)
    #expect(model.relation == nil); #expect(log.values.count == 1)
  }
  @Test @MainActor func successfulTripleCountsOnlyConfirmedOperations() async {
    ActionProtocol.handler = { request in
      if request.httpMethod != "POST" { return relationResponse(request, liked: true, coins: 1) }
      return .init(json: #"{"code":0,"data":{"like":true,"coin":true,"fav":true,"multiply":1}}"#)
    }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    #expect(await model.sendTriple(api: api))
    #expect(model.relation == VideoRelation(liked: true, coins: 2, favorited: true))
    #expect(model.counts.likes == 10); #expect(model.counts.coins == 21); #expect(model.counts.favorites == 31)
  }
  @Test @MainActor func uncertainCoinWriteNeverRetriesUntilStateReloaded() async {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      if request.httpMethod == "POST" { log.append(form(request)); throw URLError(.timedOut) }
      return relationResponse(request)
    }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    #expect(await model.sendCoins(amount: 1, limit: 2, balance: 10, alsoLike: false, api: api) == false)
    #expect(model.relation == nil); #expect(model.counts.coins == 20)
    #expect(await model.sendCoins(amount: 1, limit: 2, balance: 10, alsoLike: false, api: api) == false)
    #expect(log.values.count == 1)
  }
  @Test @MainActor func favoritesLoadMembershipAndSaveOnlyChangedFolders() async {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      if request.httpMethod == "POST" { log.append(form(request)); return .init(json: #"{"code":0,"data":{}}"#) }
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      #expect(query.contains(URLQueryItem(name: "rid", value: "123")))
      #expect(query.contains(URLQueryItem(name: "type", value: "2")))
      return .init(json: #"{"code":0,"data":{"list":[{"id":1,"title":"one","media_count":4,"fav_state":1,"attr":2},{"id":2,"title":"two","media_count":5,"fav_state":0},{"id":3,"title":"three","media_count":6,"fav_state":0}]}}"#)
    }
    let api = api(), editor = FavoriteEditor(aid: 123, mid: 1)
    await editor.load(api: api)
    #expect(editor.selected == [1]); #expect(editor.folders.first?.isPrivate == true)
    #expect(await editor.save(api: api)); #expect(log.values.isEmpty)
    editor.selected = [3, 2]
    #expect(await editor.save(api: api))
    #expect(log.values.first?["add_media_ids"] == "2,3")
    #expect(log.values.first?["del_media_ids"] == "1")
    #expect(editor.folders.map(\.count) == [3, 6, 7]); #expect(editor.original == [2, 3])
  }
  @Test @MainActor func favoriteFailureKeepsSelectionButRequiresRefreshBeforeRetry() async {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      if request.httpMethod == "POST" { log.append(form(request)); throw URLError(.networkConnectionLost) }
      return .init(json: #"{"code":0,"data":{"list":[{"id":1,"title":"one","fav_state":0}]}}"#)
    }
    let api = api(), editor = FavoriteEditor(aid: 123, mid: 1)
    await editor.load(api: api); editor.selected = [1]
    #expect(await editor.save(api: api) == false)
    #expect(editor.selected == [1]); #expect(!editor.loaded)
    #expect(await editor.save(api: api) == false); #expect(log.values.count == 1)
  }
  @Test @MainActor func newPrivateFolderUsesEncodedNameAndSelectionIsNotAppliedUntilSave() async throws {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      if request.httpMethod == "POST" {
        #expect(request.url?.path == "/x/v3/fav/folder/add")
        log.append(form(request)); return .init(json: #"{"code":0,"data":{"id":8,"title":"动画 & 音乐"}}"#)
      }
      return .init(json: #"{"code":0,"data":{"list":[]}}"#)
    }
    let api = api(), editor = FavoriteEditor(aid: 123, mid: 1)
    await editor.load(api: api)
    #expect(await editor.create(title: " 动画 & 音乐 ", isPrivate: true, api: api))
    #expect(editor.selected == [8]); #expect(editor.original.isEmpty)
    #expect(log.values.first?["privacy"] == "1"); #expect(log.values.first?["title"] == "动画 & 音乐")
    await #expect(throws: BiliError.self) { try await api.createFavoriteFolder(title: String(repeating: "长", count: 21), isPrivate: false) }
    #expect(log.values.count == 1)
  }
  @Test @MainActor func siteIdentityIsPreparedOnceBeforeMutation() async throws {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      log.append(["path": request.url!.path])
      if request.url?.path == "/x/frontend/finger/spi" { return .init(json: #"{"code":0,"data":{"b_3":"site-device","b_4":"site-device-4"}}"#) }
      #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("buvid3=site-device") == true)
      return .init(json: #"{"code":0,"data":{}}"#)
    }
    let api = api(); api.cookies.removeValue(forKey: "buvid3")
    try await api.setVideoLike(aid: 123, liked: true)
    try await api.setVideoLike(aid: 123, liked: false)
    #expect(log.values.map { $0["path"] } == ["/x/frontend/finger/spi", "/x/web-interface/archive/like", "/x/web-interface/archive/like"])
  }
  @Test @MainActor func uncertainFolderCreationRequiresReloadAndCannotCreateDuplicate() async {
    let log = RequestLog()
    ActionProtocol.handler = { request in
      if request.httpMethod == "POST" { log.append(form(request)); return .init(json: #"{"code":0,"data":{}}"#) }
      return .init(json: #"{"code":0,"data":{"list":[]}}"#)
    }
    let api = api(), editor = FavoriteEditor(aid: 123, mid: 1)
    await editor.load(api: api)
    #expect(await editor.create(title: "fixture", isPrivate: false, api: api) == false)
    #expect(!editor.loaded); #expect(!editor.saving)
    #expect(await editor.create(title: "fixture", isPrivate: false, api: api) == false)
    #expect(log.values.count == 1)
  }
  @Test @MainActor func changedSessionCannotApplyOldLikeOrLeaveBusyIndicator() async {
    ActionProtocol.handler = { request in
      if request.httpMethod == "POST" { return .init(json: #"{"code":0,"data":{}}"#, delay: 0.08) }
      return relationResponse(request)
    }
    let api = api(), model = VideoActionsModel()
    await model.load(detail: detail(), accountID: 1, api: api)
    let operation = Task { await model.toggleLike(api: api) }
    while model.operation == nil { await Task.yield() }
    api.authenticationGeneration = UUID()
    await operation.value
    #expect(model.operation == nil); #expect(model.counts.likes == 10)
    #expect(model.relation?.liked == false)
  }
  @Test func completedEpisodeStartsOverButMidpointAndUnknownDurationArePreserved() {
    #expect(Playback.restoredPosition(150.66, duration: 154) == 0)
    #expect(Playback.restoredPosition(170, duration: 154) == 0)
    #expect(Playback.restoredPosition(85, duration: 154) == 85)
    #expect(Playback.restoredPosition(85, duration: 0) == 85)
    #expect(Playback.restoredPosition(2, duration: 5) == 2)
    #expect(Playback.restoredPosition(4.8, duration: 5) == 0)
    #expect(Playback.restoredPosition(.nan, duration: 154) == 0)
  }
  @Test func shareLinkPreservesEpisodeAndPositionWithoutTrackingOrCredentials() {
    #expect(VideoShareLink.make(bvid: "BV1xx411c7mD", page: 1, seconds: nil).absoluteString == "https://www.bilibili.com/video/BV1xx411c7mD/")
    #expect(VideoShareLink.make(bvid: "BV1xx411c7mD", page: 3, seconds: 75.8).absoluteString == "https://www.bilibili.com/video/BV1xx411c7mD/?p=3&t=75")
    #expect(VideoShareLink.make(bvid: "BV1xx411c7mD", page: 1, seconds: .infinity).query == nil)
    #expect(VideoShareLink.make(bvid: "BV1xx411c7mD", page: 1, seconds: -2).query == nil)
  }
}
