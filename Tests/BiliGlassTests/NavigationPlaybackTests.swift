import AVFoundation
import Foundation
import Testing
@testable import BiliGlass

@MainActor struct NavigationPlaybackTests {
  @Test func returningToLocalVideoRestoresPausedPosition() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Vendor/BiliKitCore/Tests/BiliPlaybackTests/Fixtures/video-avc.mp4")
    let playback = Playback()
    defer { playback.stop() }
    playback.openLocal(fixture,
      video: Video(bvid: "navigation-fixture", title: "fixture", cover: "", author: "", duration: 2, views: 0),
      restoring: PlaybackResume(position: 0.5, playing: false))
    for _ in 0..<500 where playback.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(playback.error == nil)
    #expect(playback.player.currentItem?.status == .readyToPlay)
    #expect(abs(playback.player.currentTime().seconds - 0.5) < 0.1)
    #expect(playback.player.rate == 0)
  }
}
