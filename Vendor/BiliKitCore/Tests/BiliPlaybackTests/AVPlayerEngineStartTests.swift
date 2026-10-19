@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliPlayback

// Swift Testing macros reference their diagnostic comment type without qualification.
private typealias Comment = Testing.Comment

extension AVPlayerEngineSuites {
    /// 固定起播契约：DASH→HLS item 就绪即位于 playlist 起播位置；自动起播受 intent、identity、
    /// 用户暂停与 seek 约束，每个 intent 最多一次，续播 token 只允许一次从头播放。
    @Suite(.serialized, .timeLimit(.minutes(2)))
    struct AVPlayerEngineStartTests {
        /// `EXT-X-START` 让 DASH→HLS item 就绪时即精确位于起播位置（含非分段边界），可继续播放与回到开头。
        @Test
        @MainActor
        func dashItemStartsAtPlaylistStartOffset() async throws {
            let videoData = try fixtureBase64Data(
                named: "video-avc-256x144-4s-global-sidx.mp4"
            )
            let audioData = try fixtureBase64Data(
                named: "audio-aac-4s-global-sidx.mp4"
            )
            let videoURL = try #require(
                URL(string: "https://start-offset.fixture.bilivideo.com/video")
            )
            let audioURL = try #require(
                URL(string: "https://start-offset.fixture.bilivideo.com/audio")
            )
            let video = try makeFixtureTrack(
                id: 80,
                kind: .video,
                codecs: "avc1.4d400c",
                bandwidth: 100_000,
                data: videoData,
                primaryURL: videoURL,
                videoAttributes: try VideoRepresentationAttributes(
                    width: 256,
                    height: 144,
                    frameRate: 24
                )
            ).representation
            let audio = try makeFixtureTrack(
                id: 30_280,
                kind: .audio,
                codecs: "mp4a.40.2",
                bandwidth: 32_000,
                data: audioData,
                primaryURL: audioURL
            ).representation
            let transport = FixtureRangeTransport(
                media: [videoURL: videoData, audioURL: audioData]
            )
            let engine = makeFixtureEngine(bridge: makeFixtureBridge(transport))
            engine.player.isMuted = true
            defer { engine.stop() }
            let identity = PlaybackItemIdentity(bvid: "BV1StartOffset", cid: 900_010)

            for offset in [2.5, 1.37] {
                engine.stop()
                let request = PlaybackRequest(
                    media: .dash(
                        PlaybackManifest(
                            videoRepresentations: [video],
                            audioTracks: [
                                .original(representations: [audio], loudnessMetadata: nil)
                            ]
                        )
                    ),
                    startPositionSeconds: offset
                )
                let intent = PlaybackLoadIntent()
                try await engine.load(request, identity: identity, intent: intent)
                #expect(abs(engine.player.currentTime().seconds - offset) < 0.05)
                // 时间轴就绪即位于起播位置（弹幕、字幕从这里排起），起播处的系统跳变不算用户操作。
                #expect(abs(engine.currentTimelineSnapshot.positionSeconds - offset) < 0.05)

                let outcome = await engine.beginPlayback(identity: identity, intent: intent)
                guard case .resumed(let startedPosition, _) = outcome else {
                    Issue.record("起播位置 \(offset) 未报告续播：\(outcome)")
                    return
                }
                #expect(abs(startedPosition - offset) < 0.05)
                try await waitUntilTimeControlStatus(of: engine.player, is: .playing)
                try await waitForTimeline(of: engine) { snapshot in
                    snapshot.positionSeconds > offset + 0.2
                }
            }

            // 从起播位置回到开头仍按普通 seek 工作。
            #expect(engine.requestSeek(to: .zero))
            try await waitForTimeline(of: engine) { snapshot in
                snapshot.positionSeconds < 0.3
            }
        }

        @Test
        @MainActor
        func engineBeginPlaybackIsIntentGuardedAndRestartsOnce() async throws {
            let videoData = try fixtureBase64Data(
                named: "video-avc-256x144-4s-global-sidx.mp4"
            )
            let audioData = try fixtureBase64Data(
                named: "audio-aac-4s-global-sidx.mp4"
            )
            let videoURL = try #require(
                URL(string: "https://begin-playback.fixture.bilivideo.com/video")
            )
            let audioURL = try #require(
                URL(string: "https://begin-playback.fixture.bilivideo.com/audio")
            )
            let video = try makeFixtureTrack(
                id: 80,
                kind: .video,
                codecs: "avc1.4d400c",
                bandwidth: 100_000,
                data: videoData,
                primaryURL: videoURL,
                videoAttributes: try VideoRepresentationAttributes(
                    width: 256,
                    height: 144,
                    frameRate: 24
                )
            ).representation
            let audio = try makeFixtureTrack(
                id: 30_280,
                kind: .audio,
                codecs: "mp4a.40.2",
                bandwidth: 32_000,
                data: audioData,
                primaryURL: audioURL
            ).representation
            let engine = makeFixtureEngine(
                bridge: makeFixtureBridge(
                    FixtureRangeTransport(
                        media: [videoURL: videoData, audioURL: audioData]
                    )
                )
            )
            engine.player.isMuted = true
            defer { engine.stop() }
            let identity = PlaybackItemIdentity(
                bvid: "BV1BeginPlaybackFixture",
                cid: 900_002
            )
            let request = PlaybackRequest(
                media: .dash(
                    PlaybackManifest(
                        videoRepresentations: [video],
                        audioTracks: [.original(representations: [audio], loudnessMetadata: nil)]
                    )
                )
            )

            // 过期 intent、过期 identity 或已观察到的用户暂停都不能自动起播。
            let loadIntent = PlaybackLoadIntent()
            try await engine.load(request, identity: identity, intent: loadIntent)
            #expect(
                await engine.beginPlayback(
                    identity: identity,
                    intent: PlaybackLoadIntent()
                ) == .rejected
            )
            #expect(
                await engine.beginPlayback(
                    identity: PlaybackItemIdentity(
                        bvid: "BV1StalePlayback",
                        cid: identity.cid
                    ),
                    intent: loadIntent
                ) == .rejected
            )
            engine.pause()
            #expect(
                await engine.beginPlayback(
                    identity: identity,
                    intent: loadIntent
                ) == .rejected
            )

            // 起播前的用户 seek 同样优先于自动起播。
            engine.stop()
            let seekedIntent = PlaybackLoadIntent()
            try await engine.load(request, identity: identity, intent: seekedIntent)
            let loadedGeneration = engine.currentTimelineSnapshot.discontinuityGeneration
            #expect(engine.requestSeek(to: .milliseconds(100)))
            try await waitForTimeline(of: engine) { snapshot in
                snapshot.discontinuityGeneration > loadedGeneration
                    && abs(snapshot.positionSeconds - 0.1) < 0.05
            }
            #expect(
                await engine.beginPlayback(
                    identity: identity,
                    intent: seekedIntent
                ) == .rejected
            )

            // 同一 intent 最多起播一次。
            engine.stop()
            let playableIntent = PlaybackLoadIntent()
            try await engine.load(request, identity: identity, intent: playableIntent)
            #expect(
                await engine.beginPlayback(
                    identity: identity,
                    intent: playableIntent
                ) == .startedAtBeginning
            )
            #expect(
                await engine.beginPlayback(
                    identity: identity,
                    intent: playableIntent
                ) == .rejected
            )
            try await waitUntilTimeControlStatus(of: engine.player, is: .playing)

            // 从 playlist 起播位置续播；token 只允许一次“从头播放”，重叠调用只有一个成功。
            engine.stop()
            let resumeIntent = PlaybackLoadIntent()
            try await engine.load(
                PlaybackRequest(
                    media: request.media,
                    mediaHeaders: request.mediaHeaders,
                    startPositionSeconds: 1.37
                ),
                identity: identity,
                intent: resumeIntent
            )
            let resumeOutcome = await engine.beginPlayback(
                identity: identity,
                intent: resumeIntent
            )
            guard case .resumed(let resumedPosition, let resumeToken) = resumeOutcome else {
                Issue.record("从起播位置就绪的 item 未报告续播：\(resumeOutcome)")
                return
            }
            #expect(abs(resumedPosition - 1.37) < 0.05)
            try await waitUntilTimeControlStatus(of: engine.player, is: .playing)

            async let firstRestart = engine.restartFromBeginning(
                identity: identity,
                intent: resumeIntent,
                resumeToken: resumeToken
            )
            async let overlappingRestart = engine.restartFromBeginning(
                identity: identity,
                intent: resumeIntent,
                resumeToken: resumeToken
            )
            let restartResults = await [firstRestart, overlappingRestart]
            #expect(restartResults.filter { $0 }.count == 1)
            #expect(
                !(await engine.restartFromBeginning(
                    identity: identity,
                    intent: resumeIntent,
                    resumeToken: resumeToken
                ))
            )
        }
    }
}
