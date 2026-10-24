import AVFoundation
import BiliModels
import Foundation
import Testing
import Synchronization

@testable import BiliGlass

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (code, mime, data) = try Self.handler!(request)
      let r = HTTPURLResponse(
        url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": mime])!
      client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
@Suite(.serialized) struct FeatureTests {
  @Test @MainActor func concurrentAccountReadsShareOneNetworkRequest() async throws {
    let count = Mutex(0)
    FixtureProtocol.handler = { @Sendable request in
      #expect(request.url?.path == "/x/web-interface/nav")
      count.withLock { $0 += 1 }
      return (200, "application/json", Data(#"{"code":0,"data":{"isLogin":true,"mid":42,"uname":"fixture"}}"#.utf8))
    }
    defer { FixtureProtocol.handler = nil }
    let client = api()
    async let a = client.nav()
    async let b = client.nav()
    async let c = client.nav()
    let accounts = try await [a, b, c]
    #expect(accounts.allSatisfy { $0?.mid == 42 })
    #expect(count.withLock { $0 } == 1)
  }
  @MainActor func api() -> API {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [FixtureProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: c))
    api.cookies = ["SESSDATA": "fixture-session", "bili_jct": "fixture-csrf"]
    return api
  }
  @Test func downloadProgressCoalescesFrequentUpdatesAndKeepsCompletion() {
    let progress = DownloadProgress(count: 1)
    var publications = 0
    for value in 0..<1000 {
      if progress.set(0, Double(value) / 1000) != nil { publications += 1 }
    }
    #expect(publications < 10)
    #expect(progress.set(0, 1) == 1)
  }
  @Test func fixedAndRollingDanmakuDoNotShareAnOccupiedLane() {
    let items = [
      Danmaku(id: "fixed", time: 0, mode: 5, size: 25, color: 0xFFFFFF, text: "顶部"),
      Danmaku(id: "blocked", time: 1, mode: 1, size: 25, color: 0xFFFFFF, text: "滚动"),
      Danmaku(id: "roll", time: 5, mode: 1, size: 25, color: 0xFFFFFF, text: "滚动"),
      Danmaku(id: "blocked2", time: 6, mode: 5, size: 25, color: 0xFFFFFF, text: "顶部"),
    ]
    let plan = DanmakuLayout.prepare(
      items: items, size: CGSize(width: 900, height: 68),
      scale: 1, area: 0.5, duration: 8, time: 0)
    #expect(plan.map { $0.item.id } == ["fixed", "roll"])
  }
  @Test func danmakuPlanningBoundsWorkAndAvoidsFixedLaneOverlap() {
    let source = (0..<2000).map { index in
      Danmaku(
        id: String(index), time: Double(index), mode: 5, size: 25,
        color: 0xFFFFFF, text: "测试弹幕")
    }
    let rows = DanmakuLayout.prepare(
      items: source, size: CGSize(width: 900, height: 600),
      scale: 1, area: 0.5, duration: 8, time: 1000)
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { $0.item.time >= 980 && $0.item.time <= 1060 })
    for lane in Dictionary(grouping: rows, by: { $0.lane }).values {
      for pair in zip(lane, lane.dropFirst()) {
        #expect(pair.1.item.time >= pair.0.item.time + pair.0.duration)
      }
    }
  }
  @Test @MainActor func refreshExistingQualityStartsNewSession() {
    let p = Playback()
    p.detail = Detail(
      video: Video(
        bvid: "BV1xx411c7mD", title: "fixture", cover: "", author: "", duration: 4, views: 0),
      description: "", pages: [])
    p.selectedQuality = 80
    let before = p.generation
    p.retry(api: api())
    #expect(p.generation != before)
    p.stop()
    #expect(!p.loading)
    #expect(p.player.currentItem == nil)
  }
  @Test func uploaderDurationUsesLength() {
    let video = Video.parse(["bvid": "BV1xx411c7mD", "length": "3:42", "title": "fixture"])
    #expect(video?.duration == 222)
  }
  @Test func startupDeadlineCancelsPendingWork() async {
    let start = ContinuousClock.now
    await #expect(throws: BiliError.self) {
      try await withDeadline(seconds: 0.02) {
        try await Task.sleep(for: .seconds(60))
        return 1
      }
    }
    #expect(ContinuousClock.now - start < .seconds(3))
  }
  @Test func repeatedRepliesHaveStableUniqueIdentity() {
    let a = Reply.parse(["rpid": 1, "content": ["message": "a"]])!
    let b = Reply.parse(["rpid": 2, "content": ["message": "b"]])!
    #expect(Reply.deduplicated([a, a, b]).map(\.id) == [1, 2])
    #expect(Reply.deduplicated([a, b, b], excluding: [1]).map(\.id) == [2])
  }
  @Test @MainActor func childLikeUpdatesPreviewAndExpandedThread() async {
    FixtureProtocol.handler = { _ in (200, "application/json", Data(#"{"code":0,"data":{}}"#.utf8))
    }
    let child = Reply.parse(["rpid": 2, "like": 3, "content": ["message": "child"]])!
    let root = Reply.parse([
      "rpid": 1, "content": ["message": "root"],
      "replies": [["rpid": 2, "like": 3, "content": ["message": "child"]]],
    ])!
    let comments = Comments()
    comments.items = [root]
    comments.expanded[1] = [child]
    await comments.like(child, aid: 1, api: api())
    #expect(comments.items.first?.children.first?.liked == true)
    #expect(comments.expanded[1]?.first?.likes == 4)
  }
  @Test @MainActor func messageRefreshPreservesHistoryAndUpdatesRetractions() async {
    let inbox = InboxModel()
    inbox.select(
      Conversation(
        mid: 1, kind: 1, name: "fixture", face: "", preview: "", unread: 0,
        timestamp: 0, system: false))
    inbox.messages = [
      PrivateMessage.parse([
        "msg_key": "1", "timestamp": 1, "msg_type": 1,
        "content": #"{"content":"history"}"#,
      ])!,
      PrivateMessage.parse([
        "msg_key": "2", "timestamp": 2, "msg_type": 1,
        "content": #"{"content":"original"}"#,
      ])!,
    ]
    FixtureProtocol.handler = { _ in
      (
        200, "application/json",
        Data(
          #"{"code":0,"data":{"has_more":1,"messages":[{"msg_key":"2","timestamp":2,"msg_type":1,"msg_status":1,"content":"{}"},{"msg_key":"3","timestamp":3,"msg_type":1,"content":"{\"content\":\"new\"}"}]}}"#
            .utf8)
      )
    }
    await inbox.loadMessages(api: api(), markRead: false)
    #expect(inbox.messages.map(\.id) == ["1", "2", "3"])
    #expect(inbox.messages[1].text == "消息已撤回")
  }
  @Test func retractedPrivateMessageDoesNotExposeContent() {
    let message = PrivateMessage.parse([
      "msg_key": "9007199254740993", "msg_status": 1, "msg_type": 1,
      "content": #"{"content":"hidden original"}"#,
    ])
    #expect(message?.id == "9007199254740993")
    #expect(message?.text == "消息已撤回")
    #expect(message?.image == nil)
    #expect(message?.link == nil)
  }
  @Test @MainActor func nativePrivateMessageUsesDedicatedHostAndCSRF() async throws {
    let api = api()
    FixtureProtocol.handler = { request in
      if request.url?.path == "/x/web-interface/nav" {
        return (
          200, "application/json",
          Data(
            #"{"code":0,"data":{"isLogin":true,"mid":10,"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c4.png","sub_url":"https://i0.hdslb.com/bfs/wbi/932caff0ff746eab6f01bf08b70ac45.png"}}}"#
              .utf8)
        )
      }
      #expect(request.url?.host == "api.vc.bilibili.com")
      #expect(request.url?.path == "/web_im/v1/web_im/send_msg")
      #expect(request.httpMethod == "POST")
      var bytes = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let n = stream.read(&buffer, maxLength: buffer.count)
          if n <= 0 { break }
          bytes.append(contentsOf: buffer.prefix(n))
        }
      }
      let body = String(decoding: bytes, as: UTF8.self)
      #expect(body.contains("csrf_token=fixture-csrf"))
      #expect(body.contains("msg%5Breceiver_id%5D=9"))
      #expect(body.contains("hello"))
      return (
        200, "application/json",
        Data(#"{"code":0,"data":{"msg_key":"1234567890","msg_seqno":2}}"#.utf8)
      )
    }
    let inbox = InboxModel()
    let row = Conversation(
      mid: 9, kind: 1, name: "fixture", face: "", preview: "", unread: 0, timestamp: 0,
      system: false)
    inbox.select(row)
    inbox.drafts[row.id] = "hello"
    await inbox.send(api: api, account: Account(name: "fixture", mid: 10, face: ""))
    #expect(inbox.messageError == nil)
    #expect(inbox.messages.last?.text == "hello")
    #expect(inbox.drafts[row.id] == "")
  }
  @Test @MainActor func dynamicCommentsUseTheirOwnResourceType() async {
    FixtureProtocol.handler = { request in
      var bytes = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var b = [UInt8](repeating: 0, count: 2048)
        let n = stream.read(&b, maxLength: b.count)
        if n > 0 { bytes.append(contentsOf: b.prefix(n)) }
      }
      #expect(String(decoding: bytes, as: UTF8.self).contains("type=17"))
      return (200, "application/json", Data(#"{"code":0,"data":{}}"#.utf8))
    }
    let model = Comments()
    model.resourceType = 17
    model.draft = "fixture"
    await model.send(aid: 111, api: api())
    #expect(model.sendError == nil)
  }
  @Test func contiguousRangePlan() {
    let length: Int64 = 9 * 1024 * 1024 + 13
    let ranges = ParallelMediaDownload.ranges(length: length)
    #expect(ranges.count == 3)
    #expect(ranges.first?.start == 0)
    #expect(ranges.last?.endInclusive == length - 1)
    for i in 1..<ranges.count { #expect(ranges[i].start == ranges[i - 1].endInclusive + 1) }
    #expect(ParallelMediaDownload.ranges(length: 0).isEmpty)
  }
  @Test func protobufRejectsTruncatedPayload() {
    #expect(throws: BiliError.self) { try ProtoReader.decode(Data([0x0a, 0x7f, 0x01])) }
  }
  @Test func protobufModesAndUnicode() throws {
    let text = Array("你好🙂".utf8)
    let element: [UInt8] =
      [0x08, 0x07, 0x10, 0xe8, 0x07, 0x18, 0x05, 0x20, 0x19, 0x28, 0x7f, 0x3a, UInt8(text.count)]
      + text
    let data = Data([0x0a, UInt8(element.count)] + element)
    let d = try ProtoReader.decode(data)
    #expect(d.count == 1)
    #expect(d[0].time == 1)
    #expect(d[0].mode == 5)
    #expect(d[0].text == "你好🙂")
  }
  @Test @MainActor func commentPostPreservesTextAndUsesCSRF() async throws {
    let api = api()
    let text = "测试 & + 🙂"
    FixtureProtocol.handler = { request in
      #expect(request.httpMethod == "POST")
      var bytes = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let n = stream.read(&buffer, maxLength: buffer.count)
          if n <= 0 { break }
          bytes.append(contentsOf: buffer.prefix(n))
        }
      }
      let body = String(data: bytes, encoding: .utf8) ?? ""
      #expect(body.contains("csrf=fixture-csrf"))
      #expect(body.contains("%26"))
      #expect(body.contains("%2B"))
      return (
        200, "application/json",
        try JSONSerialization.data(withJSONObject: [
          "code": 0,
          "data": [
            "reply": [
              "rpid": 9, "ctime": 1, "content": ["message": text],
              "member": ["mid": "1", "uname": "fixture"],
            ]
          ],
        ])
      )
    }
    let comments = Comments()
    comments.draft = text
    await comments.send(aid: 1, api: api)
    #expect(comments.draft.isEmpty)
    #expect(comments.items.first?.message == text)
  }
  @Test @MainActor func verificationErrorKeepsDraft() async {
    FixtureProtocol.handler = { _ in
      (200, "application/json", Data(#"{"code":12015,"message":"需要验证码"}"#.utf8))
    }
    let comments = Comments()
    comments.draft = "保留草稿"
    await comments.send(aid: 1, api: api())
    #expect(comments.draft == "保留草稿")
    #expect(comments.sendError == "需要验证码")
    #expect(comments.items.isEmpty)
  }
  @Test @MainActor func unexpectedWriteEndpointIsBlocked() async {
    let api = api()
    await #expect(throws: BiliError.self) { _ = try await api.post("/unexpected", [:]) }
  }
  @Test @MainActor func pendingDownloadsSurviveRestart() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "biliglass-index-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let manager = Downloads(storageDirectory: dir)
    let v = Video(
      bvid: "BV1xx411c7mD", title: "fixture", cover: "", author: "", duration: 4, views: 0)
    let job = DownloadJob(video: v, cid: 1, qn: 80, folder: dir, cached: true)
    job.progress = 0.4
    manager.jobs = [job]
    manager.persist()
    let restored = Downloads(storageDirectory: dir)
    #expect(restored.jobs.count == 1)
    #expect(restored.jobs[0].cancelled)
    #expect(restored.jobs[0].progress == 0.4)
    #expect(restored.jobs[0].cached)
  }
  @Test func ipLocationIsPreserved() {
    let reply = Reply.parse([
      "rpid": 1, "reply_control": ["location": "IP属地：澳大利亚"], "member": ["mid": "123"],
      "content": ["message": "你好"],
    ])
    #expect(reply?.location == "IP属地：澳大利亚")
  }
  @Test @MainActor func dynamicRangeAndRate() {
    #expect(API.dynamicRange(["id": 125]) == .pq)
    #expect(API.dynamicRange(["id": 126, "color_transfer": 18]) == .hlg)
    #expect(API.frameRate("60000/1001")! > 59.9)
  }
  @Test @MainActor func repeatedOpaqueCursorWithNewRepliesContinuesButDuplicatePageStops() async throws {
    let client = api()
    let comments = Comments()
    for page in 1...3 {
      FixtureProtocol.handler = { @Sendable request in
        if request.url?.path.hasSuffix("/nav") == true { return (200, "application/json", Data(#"{"code":0,"data":{"isLogin":false}}"#.utf8)) }
        let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let pagination = try JSONSerialization.jsonObject(with: Data(params.first { $0.name == "pagination_str" }!.value!.utf8)) as! [String: String]
        #expect(pagination["offset"] == (page == 1 ? "" : "opaque-same"))
        let json: [String: Any] = ["code": 0, "data": ["cursor": ["is_end": false, "all_count": 100,
          "pagination_reply": ["next_offset": "opaque-same"]], "replies": [["rpid": min(2, page)]]]]
        return (200, "application/json", try JSONSerialization.data(withJSONObject: json))
      }
      comments.load(aid: 123, api: client, more: page > 1)
      for _ in 0..<200 where comments.loading { try await Task.sleep(for: .milliseconds(5)) }
      #expect(!comments.loading)
      #expect(comments.items.count == min(2, page))
      if page < 3 { #expect(comments.error == nil) }
      else { #expect(comments.error != nil); #expect(comments.page == 2) }
    }
    comments.stop()
  }
}
