import AVFoundation
import Testing
@testable import BiliGlass

@MainActor struct MiniPlayerSessionTests {
  @Test func navigationAndReturnKeepTheSamePlaybackItem() {
    let store = Store()
    let item = AVPlayerItem(asset: AVMutableComposition())
    store.playback.player.replaceCurrentItem(with: item)
    store.isPlaybackOpen = true; store.showPlayer = true
    let generation = store.playback.generation
    #expect(!store.showsMiniPlayer)
    store.leavePlayer()
    #expect(store.showsMiniPlayer)
    #expect(store.playback.player.currentItem === item)
    store.returnToPlayer()
    store.navigate(.web)
    #expect(store.showsMiniPlayer)
    #expect(store.playback.player.currentItem === item)
    #expect(store.playback.generation == generation)
    store.navigate(.messages)
    #expect(store.showsMiniPlayer)
    #expect(store.playback.player.currentItem === item)
    store.returnToPlayer()
    #expect(store.showPlayer); #expect(!store.showsMiniPlayer)
    #expect(store.playback.player.currentItem === item)
    #expect(store.playback.generation == generation)
    store.closeMiniPlayer()
    #expect(!store.showsMiniPlayer); #expect(!store.showPlayer)
    #expect(store.playback.player.currentItem == nil)
    #expect(store.playback.generation != generation)
  }

  @Test func returningWithoutAnOpenSessionDoesNotOpenAnEmptyPlayer() {
    let store = Store()
    store.returnToPlayer()
    #expect(!store.showPlayer); #expect(!store.showsMiniPlayer)
  }

  @Test func websiteCanReadCSRFButNotTheSessionCookie() throws {
    let csrf = try #require(WebSession.cookie(name: "bili_jct", value: "fixture-csrf"))
    let session = try #require(WebSession.cookie(name: "SESSDATA", value: "fixture-session"))
    #expect(!csrf.isHTTPOnly); #expect(session.isHTTPOnly)
    #expect(csrf.isSecure); #expect(session.isSecure)
    #expect(csrf.domain == ".bilibili.com"); #expect(csrf.path == "/")
  }
}
