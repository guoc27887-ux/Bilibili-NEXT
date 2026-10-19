import Foundation
import Testing
@testable import BiliGlass

@Suite struct RegressionTests {
  @Test func shortCommentPagesKeepOpaqueCursorAndDeduplicatePinnedReplies() throws {
    let offset = #"{"type":3,"data":{"pn":2,"seen":"a+b/=\""}}"#
    let first = try CommentPage.parse([
      "cursor": ["is_end": false, "all_count": 109, "pagination_reply": ["next_offset": offset]],
      "top": ["upper": ["rpid": 1]], "top_replies": [["rpid": 1]],
      "replies": [["rpid": 1], ["rpid": 2]]], first: true)
    #expect(first.replies.map(\.id) == [1, 2])
    #expect(first.nextOffset == offset)
    #expect(first.count == 109)
    let query = try JSONSerialization.jsonObject(with: Data(CommentPage.pagination(offset).utf8)) as? [String: String]
    #expect(query?["offset"] == offset)
    let last = try CommentPage.parse(["cursor": ["is_end": true], "replies": [["rpid": 3]]], first: false)
    #expect(last.nextOffset == nil)
    #expect(last.replies.count == 1)
  }
  @Test func missingCommentCursorIsAnErrorRatherThanFalseCompletion() {
    #expect(throws: BiliError.self) { try CommentPage.parse(["replies": []], first: true) }
    #expect(throws: BiliError.self) { try CommentPage.parse(["cursor": ["is_end": false]], first: true) }
  }
  @Test func systemNoticeRendersTextButPlainMessagesKeepLiteralJSON() throws {
    let text = ##"[{"text":"对方主动回复或关注你前，最多发送1条消息","color_day":"#9499A0"}]"##
    let content = String(decoding: try JSONSerialization.data(withJSONObject: ["content": text]), as: UTF8.self)
    let notice = try #require(PrivateMessage.parse(["msg_key": "notice", "msg_type": 18, "content": content]))
    #expect(notice.isNotice)
    #expect(notice.text == "对方主动回复或关注你前，最多发送1条消息")
    let plain = try #require(PrivateMessage.parse(["msg_key": "plain", "msg_type": 1, "content": content]))
    #expect(!plain.isNotice)
    #expect(plain.text == text)
  }
  @Test @MainActor func clearingSearchWhilePlayingDoesNotNavigateOrReplaceSession() {
    let store = Store()
    store.query = "BV1f14y1P79L"
    store.showPlayer = true
    store.destination = .history
    let generation = store.playback.generation
    store.clearSearch()
    #expect(store.query.isEmpty)
    #expect(store.showPlayer)
    #expect(store.destination == .history)
    #expect(store.playback.generation == generation)
  }
  private func box(_ kind: String, _ payload: Data) -> Data {
    let size = UInt32(payload.count + 8)
    return Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + Data(kind.utf8) + payload
  }
  private func hevcFile(complete: Bool) -> Data {
    var hvcc = Data(repeating: 0, count: 23)
    hvcc[0] = 1; hvcc[1] = 1; hvcc[12] = 120; hvcc[22] = complete ? 3 : 2
    for type: UInt8 in complete ? [32, 33, 34] : [32, 33] { hvcc += Data([type, 0, 1, 0, 2, type << 1, 1]) }
    let entry = box("hev1", Data(repeating: 0, count: 78) + box("hvcC", hvcc))
    let stsd = box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + entry)
    let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
    return box("ftyp", Data("isom0000isom".utf8)) + box("mdat", Data(repeating: 0x9A, count: 4096)) + moov
  }
  @Test func hevcCompatibilityChangesOnlySampleEntryAndNeverMediaBytes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = hevcFile(complete: true)
    try original.write(to: url)
    let offsets = try MP4Compatibility.patchOffsets(url)
    #expect(offsets.count == 1)
    try MP4Compatibility.normalizeOwnedFile(url)
    let patched = try Data(contentsOf: url)
    #expect(patched.count == original.count)
    var expected = original
    for offset in offsets { expected.replaceSubrange(Int(offset)..<Int(offset) + 4, with: Data("hvc1".utf8)) }
    #expect(patched == expected)
    #expect(try MP4Compatibility.patchOffsets(url).isEmpty)
    #expect(try VideoSignalling.parse(patched).sampleType == "hvc1")
    try hevcFile(complete: false).write(to: url)
    #expect(try MP4Compatibility.patchOffsets(url).isEmpty)
  }
  @Test func truncatedMP4DoesNotGetPatched() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(hevcFile(complete: true).dropLast(3)).write(to: url)
    #expect(throws: BiliError.self) { try MP4Compatibility.patchOffsets(url) }
  }
}
