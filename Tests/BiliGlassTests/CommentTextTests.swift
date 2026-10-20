import Testing
@testable import BiliGlass

struct CommentTextTests {
  @Test func parsesInlineEmotesWithoutChangingUnicodeOrUnknownTokens() throws {
    let raw: [String: Any] = [
      "rpid": 1,
      "content": [
        "message": "你好👨‍👩‍👧‍👦[吃瓜][吃瓜]\n[组合包_星星眼] [未知]尾",
        "emote": [
          "[吃瓜]": ["url": "http://i0.hdslb.com/bfs/emote/a.png", "meta": ["size": 1]],
          "[组合包_星星眼]": ["url": "//i1.hdslb.com/bfs/emote/b.png", "meta": ["size": 2]],
        ],
      ],
    ]
    let reply = try #require(Reply.parse(raw))
    let content = reply.textContent
    let small = try #require(content.emotes.first)
    #expect(small.url.absoluteString == "https://i0.hdslb.com/bfs/emote/a.png")
    #expect(!small.large)
    let large = try #require(content.emotes.last)
    #expect(large.large)
    #expect(content.parts == [
      .text("你好👨‍👩‍👧‍👦"), .emote(small), .emote(small), .text("\n"),
      .emote(large), .text(" [未知]"), .text("尾"),
    ])
    #expect(content.emotes.count == 2) // Repeated image requests are deduplicated.
    #expect(content.message == reply.message)
  }
  @Test func malformedAndUntrustedEmotesStayReadable() {
    let metadata: [String: Any] = [
      "[a]": ["url": "file:///tmp/a.png"],
      "[b]": ["url": "https://hdslb.com.example.org/a.png"],
      "[c]": ["url": "https://name:password@i0.hdslb.com/a.png"],
      "[d]": ["url": "javascript:alert(1)"],
    ]
    let emotes = CommentEmote.parse(metadata)
    #expect(emotes.isEmpty)
    let content = CommentTextContent(message: "原文[a][b][c][d]", emotes: emotes)
    #expect(content.parts == [.text("原文[a][b][c][d]")])
    #expect(CommentEmote.parse("unexpected").isEmpty)
  }
  @Test func childRepliesAlsoCarryEmoteMetadata() throws {
    let reply = try #require(Reply.parse(["rpid": 1, "replies": [
      ["rpid": 2, "root": 1, "content": ["message": "[doge]", "emote": [
        "[doge]": ["url": "https://i0.hdslb.com/a.png", "meta": ["size": 1]],
      ]]],
    ]]))
    #expect(reply.children.first?.textContent.emotes.count == 1)
  }
}
