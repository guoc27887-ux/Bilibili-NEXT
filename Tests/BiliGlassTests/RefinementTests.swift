import AVFoundation
import Foundation
import Testing
@testable import BiliGlass

/// URLProtocol callbacks and async tests access the queue from different executors.
private final class PendingRequests: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [PendingProtocol] = []
  func append(_ request: PendingProtocol) {
    lock.lock()
    defer { lock.unlock() }
    requests.append(request)
  }
  func takeFirst() -> PendingProtocol? {
    lock.lock()
    defer { lock.unlock() }
    return requests.isEmpty ? nil : requests.removeFirst()
  }
  var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return requests.isEmpty
  }
}

private final class PendingProtocol: URLProtocol, @unchecked Sendable {
  static let pending = PendingRequests()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { Self.pending.append(self) }
  override func stopLoading() {}
  func finish(_ data: String = #"{"code":0,"data":{}}"#) {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(data.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

@Suite(.serialized) struct RefinementTests {
  private func historyVideo(_ bvid: String = "BV16v411e7CW") -> Video {
    Video(bvid: bvid, title: "fixture", cover: "", author: "", duration: 100, views: 0)
  }
  @Test func mergedHistoryKeepsLatestEpisodeAndSeparatesAccounts() throws {
    let video = historyVideo()
    let remote = AccountHistoryEntry(video: video, cid: 1, progress: 15,
      viewedAt: Date(timeIntervalSince1970: 100), part: "P1")
    let local = HistoryEntry(video: video, positions: ["1": 15, "2": 40],
      date: Date(timeIntervalSince1970: 110), lastCID: 2, accountID: "123")
    let other = HistoryEntry(video: historyVideo("BV1xx411c7mD"), positions: ["3": 60],
      date: Date(timeIntervalSince1970: 120), lastCID: 3, accountID: "456")
    let merged = AccountHistoryEntry.merged(remote: [remote], local: [local, other], accountID: "123")
    #expect(merged.count == 1)
    #expect(merged.first?.cid == 2 && merged.first?.progress == 40 && merged.first?.isLocal == true)
    let newer = AccountHistoryEntry(video: video, cid: 1, progress: 50,
      viewedAt: Date(timeIntervalSince1970: 130), part: "P1")
    #expect(AccountHistoryEntry.merged(remote: [remote, newer], local: [local], accountID: "123").first?.progress == 50)
  }
  @Test func legacyHistoryDecodesWithoutInventingLatestEpisode() throws {
    let entry = HistoryEntry(video: historyVideo(), positions: ["11": 10, "22": 20], date: Date())
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    json.removeValue(forKey: "lastCID"); json.removeValue(forKey: "accountID")
    let legacy = try JSONDecoder().decode(HistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.accountID == nil)
    #expect(AccountHistoryEntry.merged(remote: [], local: [legacy], accountID: "123").first?.cid == 0)
    var single = legacy; single.positions = ["22": 20]
    #expect(AccountHistoryEntry.merged(remote: [], local: [single], accountID: "123").first?.cid == 22)
  }
  private func requestBody(_ request: URLRequest) -> String {
    if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open(); defer { stream.close() }
    var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
    while true {
      let count = stream.read(&bytes, maxLength: bytes.count)
      if count <= 0 { break }
      data.append(contentsOf: bytes.prefix(count))
    }
    return String(decoding: data, as: UTF8.self)
  }
  @MainActor private func waitForSync(_ sync: WatchHistorySync) async throws {
    for _ in 0..<1000 where sync.syncing { try await Task.sleep(for: .milliseconds(2)) }
    #expect(!sync.syncing)
  }
  @Test @MainActor func viewingSyncThrottlesAndFlushesLatestPositionInOrder() async throws {
    let api = api(), sync = WatchHistorySync(enabled: { true })
    let now = Date(timeIntervalSince1970: 100)
    sync.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 5, now: now)
    let first = try await nextRequest()
    #expect(first.request.httpMethod == "POST")
    #expect(first.request.url?.path == "/x/v2/history/report")
    #expect(first.request.value(forHTTPHeaderField: "Referer") == "https://www.bilibili.com/video/BV16v411e7CW/")
    #expect(requestBody(first.request) == "aid=123&cid=55&csrf=fixture&progress=5")
    sync.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 10, now: now.addingTimeInterval(5))
    sync.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 12, final: true, now: now.addingTimeInterval(7))
    sync.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 15, final: true, now: now.addingTimeInterval(8))
    #expect(PendingProtocol.pending.isEmpty)
    first.finish()
    let last = try await nextRequest()
    #expect(requestBody(last.request).contains("progress=15"))
    last.finish()
    try await waitForSync(sync)
    sync.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 15, final: true)
    #expect(!sync.syncing && PendingProtocol.pending.isEmpty)
  }
  @Test @MainActor func viewingSyncFailureCanRecoverAndDisabledSyncNeverWrites() async throws {
    let api = api(), sync = WatchHistorySync(enabled: { true })
    let now = Date()
    sync.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 5, now: now)
    let first = try await nextRequest()
    first.finish(#"{"code":-500,"message":"fixture unavailable"}"#)
    try await waitForSync(sync)
    #expect(sync.error != nil)
    sync.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 40, now: now.addingTimeInterval(35))
    let retry = try await nextRequest(); retry.finish()
    try await waitForSync(sync)
    #expect(sync.error == nil)
    let disabled = WatchHistorySync(enabled: { false })
    disabled.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 50)
    #expect(!disabled.syncing && PendingProtocol.pending.isEmpty)
  }
  @Test @MainActor func accountChangeDoesNotSendQueuedViewingProgress() async throws {
    let api = api(), sync = WatchHistorySync(enabled: { true })
    sync.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 5)
    let first = try await nextRequest()
    sync.record(api: api, aid: 123, bvid: "BV16v411e7CW", cid: 55, seconds: 10, final: true)
    api.authenticationGeneration = UUID()
    first.finish()
    try await waitForSync(sync)
    #expect(PendingProtocol.pending.isEmpty && sync.error == nil)
    sync.reset()
  }
  @Test func commentLinksUseNativeVideoTargetsAndDropTracking() {
    let links = CommentVideoLink.parse(message:
      "分享 https://b23.tv/abc?spm_id=123 https://b23.tv/abc https://www.bilibili.com/video/av123。 https://evil.example/video/BV16v411e7CW",
      jumps: ["https://b23.tv/abc?spm_id=123": ["title": "标题"]])
    #expect(links.count == 2)
    #expect(links.first?.title == "标题")
    #expect(links.first?.url.absoluteString == "https://b23.tv/abc")
    #expect(links.last?.url.absoluteString == "https://www.bilibili.com/video/av123")
    #expect(CommentVideoLink.allowedURL("https://bilibili.com.evil.example/video/av1") == nil)
    #expect(CommentVideoLink.allowedURL("https://password@b23.tv/abc") == nil)
    #expect(CommentVideoLink.allowedURL("file:///video/av1") == nil)
  }
  @Test @MainActor func commentVideoMetadataIsCachedAcrossRows() async throws {
    let api = api(), resolver = CommentVideoLinks()
    let link = CommentVideoLink(url: URL(string: "https://www.bilibili.com/video/av123")!, title: "")
    let first = Task { await resolver.resolve(link, api: api) }
    let request = try await nextRequest()
    #expect(URLComponents(url: request.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "aid", value: "123")) == true)
    request.finish(#"{"code":0,"data":{"bvid":"BV16v411e7CW","title":"video"}}"#)
    #expect(await first.value?.bvid == "BV16v411e7CW")
    #expect(await resolver.resolve(link, api: api)?.title == "video")
    #expect(PendingProtocol.pending.isEmpty)
  }
  @Test @MainActor func accountHistoryUsesServerCursorAndPreservesRowsOnFailure() async throws {
    let api = api(), history = AccountHistory()
    let first = Task { await history.load(api: api) }
    let request = try await nextRequest()
    #expect(request.request.url?.path == "/x/web-interface/history/cursor")
    request.finish(#"{"code":0,"data":{"cursor":{"max":11,"view_at":100,"business":"archive"},"list":[{"title":"video","cover":"https://i0.hdslb.com/a.png","author_name":"author","duration":100,"progress":20,"view_at":100,"history":{"business":"archive","bvid":"BV16v411e7CW","cid":55}}]}}"#)
    await first.value
    #expect(history.items.first?.cid == 55)
    #expect(history.items.first?.progress == 20)
    #expect(history.hasMore)
    let more = Task { await history.load(api: api) }
    let next = try await nextRequest()
    let query = URLComponents(url: next.request.url!, resolvingAgainstBaseURL: false)?.queryItems
    #expect(query?.contains(URLQueryItem(name: "max", value: "11")) == true)
    #expect(query?.contains(URLQueryItem(name: "view_at", value: "100")) == true)
    next.finish(#"{"code":-500,"message":"fixture failed"}"#)
    await more.value
    #expect(history.items.count == 1)
    #expect(history.error != nil)
    let stale = Task { await history.load(api: api) }
    let staleRequest = try await nextRequest()
    history.reset()
    staleRequest.finish(#"{"code":0,"data":{"list":[{"history":{"business":"archive","bvid":"BV16v411e7CW"}}]}}"#)
    await stale.value
    #expect(history.items.isEmpty)
    #expect(!history.loading)
  }
  @MainActor private func api() -> API {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PendingProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config))
    api.cookies = ["SESSDATA": "fixture", "bili_jct": "fixture"]
    return api
  }
  private func nextRequest() async throws -> PendingProtocol {
    let end = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < end {
      if let first = PendingProtocol.pending.takeFirst() { return first }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw BiliError(text: "Expected a fixture request")
  }
  @Test @MainActor func oldCommentResponseCannotUnlockNewComposer() async throws {
    let api = api(), comments = Comments()
    comments.draft = "old"
    let first = Task { await comments.send(aid: 1, api: api) }
    let old = try await nextRequest()
    comments.stop()
    #expect(!comments.sending)
    comments.draft = "new"
    let second = Task { await comments.send(aid: 2, api: api) }
    let new = try await nextRequest()
    old.finish()
    await first.value
    #expect(comments.sending)
    #expect(comments.draft == "new")
    new.finish()
    await second.value
    #expect(!comments.sending)
    #expect(comments.draft.isEmpty)
  }
  @Test @MainActor func changedAccountDiscardsPendingRead() async throws {
    let api = api()
    let task = Task { _ = try await api.request("/x/web-interface/nav") }
    let pending = try await nextRequest()
    api.authenticationGeneration = UUID()
    pending.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
  @Test @MainActor func replyingKeepsExistingChildrenAndShowsSubmissionRecord() async throws {
    let comments = Comments(), api = api()
    let parent = try #require(Reply.parse(["rpid": 1, "rcount": 1, "content": ["message": "parent"],
      "replies": [["rpid": 2, "root": 1, "content": ["message": "existing"]]]]))
    comments.items = [parent]
    comments.replyingTo = parent
    comments.draft = "new reply"
    let task = Task { await comments.send(aid: 1, api: api) }
    let pending = try await nextRequest()
    pending.finish(#"{"code":0,"data":{"success_toast":"发送成功","reply":{"rpid":3,"root":1,"content":{"message":"new reply"}}}}"#)
    await task.value
    #expect(comments.expanded[1]?.map(\.id) == [2, 3])
    #expect(comments.items.first?.count == 2)
    comments.collapse(parent)
    #expect(comments.items.first?.children.map(\.id) == [2, 3])
    #expect(comments.submittedText == "new reply")
    #expect(comments.submissionStatus == "发送成功")
  }
  @Test @MainActor func acceptedCommentWithoutReplyIsNotSilentlyLost() async throws {
    let comments = Comments(), api = api()
    comments.draft = "submitted text"
    let task = Task { await comments.send(aid: 1, api: api) }
    let pending = try await nextRequest()
    pending.finish(#"{"code":0,"data":{"rpid":123,"reply":null,"success_toast":"审核中"}} "#)
    await task.value
    #expect(comments.submittedText == "submitted text")
    #expect(comments.submissionStatus?.contains("审核中") == true)
    #expect(comments.submissionStatus?.contains("尚未返回") == true)
    #expect(comments.items.isEmpty)
  }
  @Test @MainActor func commentCountDistinguishesUnknownZeroAndFailedRefresh() async throws {
    let comments = Comments(), api = api()
    #expect(!comments.hasLoadedCount)
    comments.loadIfNeeded(aid: 1, api: api)
    #expect(!comments.hasLoadedCount)
    let nav = try await nextRequest()
    nav.finish(#"{"code":0,"data":{"wbi_img":{"img_url":"https://i0.hdslb.com/0123456789abcdef0123456789abcdef.png","sub_url":"https://i0.hdslb.com/abcdef0123456789abcdef0123456789.png"}}}"#)
    let first = try await nextRequest()
    first.finish(#"{"code":0,"data":{"cursor":{"is_end":true,"all_count":0},"replies":[]}}"#)
    for _ in 0..<200 where comments.loading { try await Task.sleep(for: .milliseconds(2)) }
    #expect(comments.hasLoadedCount)
    #expect(comments.count == 0)
    comments.load(aid: 1, api: api)
    let refresh = try await nextRequest()
    refresh.finish(#"{"code":-500,"message":"fixture unavailable"}"#)
    for _ in 0..<200 where comments.loading { try await Task.sleep(for: .milliseconds(2)) }
    #expect(comments.hasLoadedCount)
    #expect(comments.count == 0)
    #expect(comments.error != nil)
    comments.loadIfNeeded(aid: 2, api: api)
    #expect(!comments.hasLoadedCount)
    comments.stop()
  }
  @Test @MainActor func failedRefreshKeepsCommentsAndReappearingViewDoesNotReload() async throws {
    let comments = Comments(), api = api()
    comments.loadIfNeeded(aid: 1, api: api)
    let nav = try await nextRequest()
    nav.finish(#"{"code":0,"data":{"wbi_img":{"img_url":"https://i0.hdslb.com/0123456789abcdef0123456789abcdef.png","sub_url":"https://i0.hdslb.com/abcdef0123456789abcdef0123456789.png"}}}"#)
    let first = try await nextRequest()
    first.finish(#"{"code":0,"data":{"cursor":{"is_end":true,"all_count":1},"replies":[{"rpid":1,"rcount":1,"replies":[{"rpid":2,"root":1}]}]}}"#)
    for _ in 0..<200 where comments.loading { try await Task.sleep(for: .milliseconds(2)) }
    #expect(comments.items.map(\.id) == [1])
    comments.expanded[1] = comments.items[0].children
    comments.loadIfNeeded(aid: 1, api: api)
    #expect(!comments.loading)
    comments.load(aid: 1, api: api)
    let refresh = try await nextRequest()
    #expect(comments.items.map(\.id) == [1])
    #expect(comments.expanded[1]?.map(\.id) == [2])
    refresh.finish(#"{"code":-500,"message":"fixture unavailable"}"#)
    for _ in 0..<200 where comments.loading { try await Task.sleep(for: .milliseconds(2)) }
    #expect(comments.error != nil)
    #expect(comments.items.map(\.id) == [1])
    #expect(comments.expanded[1]?.map(\.id) == [2])
    comments.stop()
  }
  @Test @MainActor func messageCategoryDoesNotKeepPreviousConversation() async throws {
    let api = api(), inbox = InboxModel()
    let conversation = Conversation(mid: 42, kind: 1, name: "fixture", face: "", preview: "",
                                    unread: 0, timestamp: 0, system: false)
    inbox.select(conversation)
    inbox.conversations = [conversation]
    inbox.hasOlder = true
    inbox.drafts[conversation.id] = "keep this draft"
    let task = Task { await inbox.load(api: api, systemOnly: true) }
    let pending = try await nextRequest()
    #expect(inbox.selected == nil)
    #expect(!inbox.hasOlder)
    pending.finish(#"{"code":0,"data":{"session_list":[],"has_more":0}}"#)
    await task.value
    #expect(inbox.conversations.isEmpty)
    #expect(inbox.drafts[conversation.id] == "keep this draft")
  }
  @Test @MainActor func cancelledDownloadRetryCannotRestartAfterPreviousTaskFinishes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let downloads = Downloads(storageDirectory: directory)
    let video = Video(bvid: "fixture", title: "test", cover: "", author: "", duration: 1, views: 0)
    let job = DownloadJob(video: video, cid: 1, qn: 80, folder: directory)
    downloads.jobs = [job]
    var release: CheckedContinuation<Void, Never>?
    job.task = Task { await withCheckedContinuation { release = $0 } }
    while release == nil { await Task.yield() }
    downloads.retry(job, api: api())
    let retry = job.task
    downloads.pause(job)
    release?.resume()
    await retry?.value
    #expect(job.cancelled)
    #expect(job.status == "已暂停")
    #expect(PendingProtocol.pending.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Transfers/\(job.id)").path))
  }
  @Test func videoPageRemovesDuplicatesWithinAndAcrossPages() {
    let a = Video(bvid: "a", title: "", cover: "", author: "", duration: 0, views: 0)
    let b = Video(bvid: "b", title: "", cover: "", author: "", duration: 0, views: 0)
    #expect(Video.deduplicated([a, a, b, b]).map(\.id) == ["a", "b"])
    #expect(Video.deduplicated([a, b, b], excluding: ["a"]).map(\.id) == ["b"])
  }
  @Test func sharesParseOldAVNewBVAndRetractions() throws {
    let old = try #require(MessageShare.parse(["source": 5, "id": "246551172", "title": "video",
      "thumb": "http://i0.hdslb.com/image.jpg", "author": "author"], type: 7))
    #expect(old.aid == 246551172)
    #expect(old.bvid == nil)
    #expect(old.cover == "https://i0.hdslb.com/image.jpg")
    #expect(old.author == "author")
    let new = try #require(MessageShare.parse(["source": 5, "bvid": "BV16v411e7CW"], type: 7))
    #expect(new.bvid == "BV16v411e7CW")
    let article = try #require(MessageShare.parse(["source": 6, "id": 123], type: 7))
    #expect(!article.isVideo && article.aid == nil)
    let raw: [String: Any] = ["msg_key": "1", "msg_type": 7, "msg_status": 1,
      "content": #"{"source":5,"id":246551172,"title":"hidden"}"#]
    let removed = try #require(PrivateMessage.parse(raw))
    #expect(removed.share == nil)
    #expect(removed.text == "消息已撤回")
    #expect(MessageShare.parse(["source": 5, "url": "javascript:alert(1)", "thumb": "file:///tmp/a"], type: 7)?.url == nil)
  }
  @Test @MainActor func olderVideoSharesResolveThroughNativeVideoAPI() async throws {
    let share = try #require(MessageShare.parse(["source": 5, "id": 246551172], type: 7))
    let api = api()
    let task = Task { try await share.resolveVideo(api: api) }
    let pending = try await nextRequest()
    #expect(pending.request.url?.path == "/x/web-interface/view")
    #expect(URLComponents(url: pending.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "246551172")
    pending.finish(#"{"code":0,"data":{"bvid":"BV16v411e7CW"}}"#)
    #expect(try await task.value == "BV16v411e7CW")
  }
  @Test @MainActor func stoppingDanmakuCancelsLocalImportAndResetsComposer() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let items = (0..<10000).map { Danmaku(id: String($0), time: Double($0), mode: 1, size: 25, color: 0xFFFFFF, text: "fixture") }
    try JSONEncoder().encode(items).write(to: url)
    let controller = DanmakuController()
    controller.start(cid: 1, api: api(), player: AVPlayer(), localSidecar: url)
    controller.sending = true
    controller.stop()
    try await Task.sleep(for: .milliseconds(80))
    #expect(controller.items.isEmpty)
    #expect(!controller.sending)
  }
}
