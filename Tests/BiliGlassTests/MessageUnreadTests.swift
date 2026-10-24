import Foundation
import Testing
@testable import BiliGlass

private final class UnreadProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
    let data: [String: Any] = request.url!.path.hasSuffix("single_unread")
      ? ["follow_unread": 3, "unfollow_unread": 2]
      : ["reply": 4, "at": 2, "like": 7, "recv_like": 7, "recv_reply": 6]
    let body = try! JSONSerialization.data(withJSONObject: ["code": cookie.contains("offline") ? -500 : 0, "data": data])
    let send: @Sendable () -> Void = { [self] in
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
    if cookie.contains("delayed") { DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: send) }
    else { send() }
  }
  override func stopLoading() {}
}
@MainActor struct MessageUnreadTests {
  private func api(_ session: String = "fixture") -> API {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UnreadProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config))
    api.cookies = ["SESSDATA": session, "bili_jct": "fixture", "DedeUserID": "1"]
    return api
  }
  @Test func independentCategoriesDoNotDoubleCountAliases() {
    var counts = MessageUnreadCounts()
    let applied1 = counts.applyFeed(["reply": 4, "at": "2", "like": 7, "recv_like": 7, "recv_reply": 6])
    #expect(applied1)
    let applied2 = counts.applyPrivate(["follow_unread": 3, "unfollow_unread": 2, "biz_msg_follow_unread": 3, "dustbin_unread": 99])
    #expect(applied2)
    #expect(counts.total == 18 && counts[1] == 4 && counts[2] == 2 && counts[3] == 7 && counts[0] == 5)
  }
  @Test func malformedCountersDoNotEraseKnownCounts() {
    var counts = MessageUnreadCounts(replies: 2, mentions: 3, likes: 4, privateMessages: 5)
    let applied3 = !counts.applyFeed(["recv_reply": 99, "like": 0])
    #expect(applied3)
    let applied4 = !counts.applyPrivate([:])
    #expect(applied4)
    #expect(counts.total == 14)
    let applied5 = counts.applyFeed(["reply": -5, "at": 0, "recv_like": "8"])
    #expect(applied5)
    #expect(counts.replies == 0 && counts.likes == 8)
  }
  @Test func failurePreservesCountsAndRetryClearsError() async {
    let api = api(); defer { api.session.invalidateAndCancel() }
    let model = MessageUnreadModel()
    await model.refresh(api: api)
    #expect(model.counts.total == 18 && model.error == nil)
    api.cookies["SESSDATA"] = "offline"
    await model.refresh(api: api)
    #expect(model.counts.total == 18 && model.error != nil)
    api.cookies["SESSDATA"] = "fixture"
    await model.refresh(api: api)
    #expect(model.counts.total == 18 && model.error == nil)
    api.cookies = [:]
    await model.refresh(api: api)
    #expect(model.counts.total == 0 && model.error == nil)
  }
  @Test func oldAccountResponseCannotRepopulateAfterReset() async throws {
    let api = api("delayed"); defer { api.session.invalidateAndCancel() }
    let model = MessageUnreadModel()
    let request = Task { await model.refresh(api: api) }
    try await Task.sleep(for: .milliseconds(20))
    api.authenticationGeneration = UUID(); model.reset()
    await request.value
    #expect(model.counts.total == 0)
  }
  @Test func likesDescribeObjectAndAggregatePeopleWithoutReplyAction() throws {
    let video = try #require(NativeNotice.parse(["id": 1, "counts": 12,
      "users": [["nickname": "小明"]], "item": ["business": "视频", "title": "视频标题", "source_content": "", "native_uri": "bilibili://video/123"]], kind: 3))
    #expect(video.headline == "小明等 12 人赞了你的视频")
    #expect(video.text == "视频标题" && video.quote.isEmpty && video.commentTarget == nil)
    #expect(video.originalPageURL?.absoluteString == "https://www.bilibili.com/video/av123/")
    let comment = try #require(NativeNotice.parse(["id": 2, "users": [["nickname": "小红"]],
      "item": ["business": "评论", "title": "我的评论", "subject_id": 123, "business_id": 1, "source_id": 22]], kind: 3))
    #expect(comment.headline == "小红赞了你的评论" && comment.commentTarget == nil)
    let unknown = try #require(NativeNotice.parse(["id": 3, "item": ["business_id": 1]], kind: 3))
    #expect(unknown.action == "赞了你的内容")
  }
  @Test func replyAndMentionKeepExactCommentTarget() throws {
    let raw: [String: Any] = ["id": 3, "user": ["nickname": "朋友"], "item": ["subject_id": 123, "business_id": 1, "source_id": 22, "root_id": 11, "source_content": "回复正文", "target_reply_content": "原评论"]]
    let reply = try #require(NativeNotice.parse(raw, kind: 1))
    let mention = try #require(NativeNotice.parse(raw, kind: 2))
    #expect(reply.headline == "朋友回复了你" && mention.headline == "朋友提到了你")
    #expect(reply.commentTarget?.replyID == 22 && reply.quote == "原评论")
  }
}
