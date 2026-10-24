import Foundation
import Testing
@testable import BiliGlass

private final class NoticeReplyProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let data: [String: Any]
    if request.url?.path == "/x/web-interface/nav" {
      data = ["wbi_img": ["img_url": "https://i0.hdslb.com/bfs/wbi/abcdefghijklmnopqrstuvwxyz012345.png", "sub_url": "https://i0.hdslb.com/bfs/wbi/012345abcdefghijklmnopqrstuvwxyz.png"]]
    } else if request.url?.path == "/x/v2/reply/add" {
      data = ["success_toast": "回复成功", "reply": ["rpid": 33, "root": 11, "member": ["mid": "1", "uname": "me"], "content": ["message": "new reply"]]]
    } else if request.url?.path == "/x/v2/reply/reply" {
      data = ["root": ["rpid": 11, "rcount": 2], "page": ["count": 2], "replies": [
        ["rpid": 22, "root": 11, "content": ["message": "the exact reply"]],
        ["rpid": 23, "root": 11, "content": ["message": "existing conversation"]]
      ]]
    } else {
      let seek = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "seek_rpid" }?.value
      data = ["replies": seek == "22" ? [["rpid": 11, "replies": [["rpid": 22, "root": 11, "content": ["message": "the exact reply"]]]]] : [["rpid": 99]]]
    }
    let body = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
@MainActor struct NoticeCommentTests {
  @Test func notificationTargetsIncomingReplyNotOlderParent() throws {
    let target = try #require(NoticeCommentTarget.parse(["subject_id": "9007199254740993", "business_id": 17, "source_id": "22", "target_id": 33, "root_id": 11]))
    #expect(target.oid == 9007199254740993 && target.replyID == 22 && target.rootID == 11)
    #expect(NoticeCommentTarget.parse(["subject_id": 1, "business_id": 1, "source_id": 0]) == nil)
    #expect(NoticeCommentTarget.parse(["subject_id": 1, "business_id": 999, "source_id": 22]) == nil)
  }
  @Test func seekFindsExactNestedReplyAndNeverSubstitutesAnotherComment() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NoticeReplyProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config))
    defer { api.session.invalidateAndCancel() }
    let comments = Comments()
    let found = await comments.loadFocused(.init(oid: 123, type: 1, replyID: 22, rootID: 11), api: api)
    #expect(found?.id == 22 && found?.root == 11)
    #expect(comments.items.map(\.id) == [22])
    #expect(comments.resourceType == 1 && !comments.loading)
    #expect(comments.focusedReplies.map(\.id) == [23])
    let absent = await comments.loadFocused(.init(oid: 123, type: 1, replyID: 44, rootID: 0), api: api)
    #expect(absent == nil && comments.items.isEmpty && comments.error != nil)
    #expect(!comments.loading)
  }
  @Test func replyFromNoticeStaysVisibleAfterComposerCloses() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NoticeReplyProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config))
    api.cookies = ["SESSDATA": "fixture", "bili_jct": "fixture"]
    defer { api.session.invalidateAndCancel() }
    let comments = Comments()
    comments.replyingTo = await comments.loadFocused(.init(oid: 123, type: 1, replyID: 22, rootID: 11), api: api)
    comments.draft = "new reply"
    await comments.send(aid: 123, api: api)
    #expect(comments.replyingTo == nil && !comments.sending && comments.sendError == nil)
    #expect(comments.items.map(\.id) == [22])
    #expect(comments.focusedReplies.map(\.id) == [23, 33])
    #expect(comments.focusedReplies.last?.message == "new reply")
    #expect(comments.submittedText == "new reply" && comments.submissionStatus == "回复成功")
    comments.stop()
    #expect(comments.focusedRoot == nil && comments.focusedReplies.isEmpty)
  }
  @Test func originalPageUsesHTTPSAndConvertsVideoAppLinks() throws {
    let raw: [String: Any] = ["id": 1, "item": ["subject_id": 123, "business_id": 1, "source_id": 22, "uri": "bilibili://video/123"]]
    var notice = try #require(NativeNotice.parse(raw))
    #expect(notice.originalPageURL?.absoluteString == "https://www.bilibili.com/video/av123/#reply22")
    notice.commentTarget = nil
    #expect(notice.originalPageURL?.absoluteString == "https://www.bilibili.com/video/av123/")
    let web = try #require(NativeNotice.parse(["id": 2, "item": ["uri": "http://www.bilibili.com/video/BV1xx411c7mD/?p=2#reply22"]]))
    #expect(web.originalPageURL?.absoluteString == "https://www.bilibili.com/video/BV1xx411c7mD/?p=2#reply22")
  }
}
