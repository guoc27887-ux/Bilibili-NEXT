import AVFoundation
import Foundation
import Testing
@testable import BiliGlass

private final class UnavailableQualityProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
  override func stopLoading() {}
}

@MainActor struct QualitySwitchTests {
  @Test(arguments: [false, true])
  func rapidSwitchAndFailedRetryKeepPositionAndPlaybackIntent(playing: Bool) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UnavailableQualityProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: configuration))
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Vendor/BiliKitCore/Tests/BiliPlaybackTests/Fixtures/video-avc.mp4")
    let playback = Playback()
    defer { playback.stop(); api.session.invalidateAndCancel() }
    playback.detail = Detail(video: Video(bvid: "BV16v411e7CW", title: "fixture", cover: "", author: "",
      duration: 2, views: 0), description: "", pages: [Page(id: 55, title: "", number: 1)])
    playback.selectedCID = 55; playback.selectedQuality = 80
    let item = AVPlayerItem(url: fixture)
    playback.player.replaceCurrentItem(with: item)
    for _ in 0..<200 where item.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
    #expect(item.status == .readyToPlay)
    #expect(await playback.player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600),
      toleranceBefore: .zero, toleranceAfter: .zero))
    if playing { playback.player.playImmediately(atRate: 1) }
    let position = playback.player.currentTime().seconds
    #expect(position >= 0.49)
    playback.selectQuality(64, api: api)
    let firstGeneration = playback.generation
    #expect(playback.player.currentItem == nil)
    #expect(playback.pendingResume?.playing == playing)
    playback.selectQuality(80, api: api) // Back to the original quality while 720P is still pending.
    #expect(playback.generation != firstGeneration)
    #expect(playback.requestedQuality == 80)
    playback.selectQuality(32, api: api)
    #expect(abs((playback.pendingResume?.position ?? -1) - position) < 0.1)
    #expect(playback.positionSeconds >= 0.49)
    for _ in 0..<200 where playback.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(playback.error != nil)
    #expect(playback.requestedQuality == 32)
    playback.retry(api: api)
    #expect(playback.requestedQuality == 32)
    #expect(abs((playback.pendingResume?.position ?? -1) - position) < 0.1)
    #expect(playback.pendingResume?.playing == playing)
    playback.togglePlayback()
    #expect(playback.pendingResume?.playing == !playing)
    playback.stop()
    let stopped = playback.generation
    try await Task.sleep(for: .milliseconds(30))
    #expect(playback.generation == stopped)
    #expect(playback.pendingResume == nil && playback.requestedQuality == nil)
    #expect(!playback.loading && playback.error == nil)
  }
}
