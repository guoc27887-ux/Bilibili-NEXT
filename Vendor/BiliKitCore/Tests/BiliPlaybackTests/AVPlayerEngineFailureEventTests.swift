@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

/// 固定播放失败事件的订阅契约：每次 `playbackFailureEvents()` 都是独立订阅，取消其中一个不结束其他订阅。
@Suite(.serialized, .timeLimit(.minutes(2)))
struct AVPlayerEngineFailureEventTests {
    @Test
    @MainActor
    func everyLiveSubscriberReceivesTheFailureAfterAnotherIsCancelled() async throws {
        let fixture = try makeSimpleMedia(host: "failure-subscribers.fixture.bilivideo.com")
        let engine = makeFixtureEngine(
            bridge: makeFixtureBridge(FixtureRangeTransport(media: fixture.media))
        )
        engine.player.isMuted = true
        defer { engine.stop() }
        let cancelled = engine.playbackFailureEvents()
        var first = engine.playbackFailureEvents().makeAsyncIterator()
        var second = engine.playbackFailureEvents().makeAsyncIterator()
        let cancelledConsumer = Task {
            for await _ in cancelled {}
        }
        cancelledConsumer.cancel()
        await cancelledConsumer.value
        let identity = PlaybackItemIdentity(bvid: "BV1FailureSubscribers", cid: 900_020)

        try await engine.load(
            PlaybackRequest(
                media: .dash(
                    PlaybackManifest(
                        videoRepresentations: [fixture.video],
                        audioTracks: [
                            .original(representations: [fixture.audio], loudnessMetadata: nil)
                        ]
                    )
                )
            ),
            identity: identity
        )
        let item = try #require(engine.player.currentItem)
        NotificationCenter.default.post(
            name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item
        )

        #expect(await first.next()?.identity == identity)
        #expect(await second.next()?.identity == identity)
    }
}
