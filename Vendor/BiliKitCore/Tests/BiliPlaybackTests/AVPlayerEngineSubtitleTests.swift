@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliPlayback

extension AVPlayerEngineSuites {
    /// 固定原生字幕接入契约：字幕 reset 跨 A→B→A 的 load 串行且旧 generation 被拒，
    /// 不可用的字幕目录或不配合的 repository 都退回只含媒体的 master playlist。
    @Suite(.serialized, .timeLimit(.minutes(2)))
    struct AVPlayerEngineSubtitleTests {
        @Test
        @MainActor
        func engineSerializesSubtitleResetAcrossABALoads() async throws {
            let fixture = try makeSimpleMedia(host: "native-subtitle.fixture.bilivideo.com")
            let subtitleRepository = FixtureSubtitleRepository(
                catalog: .tracks([
                    SubtitleTrack(
                        id: "standard-zh",
                        languageCode: "zh",
                        displayName: "中文",
                        kind: .standard
                    )
                ]),
                holdsReset: true
            )
            let engine = makeFixtureEngine(
                bridge: makeFixtureBridge(FixtureRangeTransport(media: fixture.media)),
                subtitleRepository: subtitleRepository
            )
            engine.player.isMuted = true
            let request = PlaybackRequest(
                media: .dash(
                    PlaybackManifest(
                        videoRepresentations: [fixture.video],
                        audioTracks: [
                            .original(representations: [fixture.audio], loudnessMetadata: nil)
                        ]
                    )
                )
            )
            let firstA = PlaybackItemIdentity(bvid: "BV1NativeA", cid: 101)
            let itemB = PlaybackItemIdentity(bvid: "BV1NativeB", cid: 202)

            try await engine.load(request, identity: firstA)

            let blockedBLoad = Task {
                try await engine.load(request, identity: itemB)
            }
            await subtitleRepository.waitForResetCalls(1)
            let replacementALoad = Task {
                try await engine.load(request, identity: firstA)
            }
            #expect(await subtitleRepository.trackRequests == [firstA])

            await subtitleRepository.releaseReset()
            // 旧 reset 返回后，较新的 A generation 必须拒绝 B。
            await #expect(throws: CancellationError.self) {
                try await blockedBLoad.value
            }
            try await replacementALoad.value
            #expect(await subtitleRepository.trackRequests == [firstA, firstA])

            let stoppedBLoad = Task {
                try await engine.load(request, identity: itemB)
            }
            await subtitleRepository.waitForResetCalls(2)
            engine.stop()
            await subtitleRepository.releaseReset()
            // stop 在字幕准备前让排队中的 load 失效。
            await #expect(throws: CancellationError.self) {
                try await stoppedBLoad.value
            }
            #expect(await subtitleRepository.trackRequests == [firstA, firstA])
            #expect(await subtitleRepository.resetCalls == [firstA, firstA])
            #expect(engine.player.currentItem == nil)
        }

        @Test(arguments: UnusableNativeSubtitleCatalog.allCases)
        func unusableSubtitleCatalogFallsBackToMediaOnly(
            _ catalog: UnusableNativeSubtitleCatalog
        ) async throws {
            let fixture = try makeSimpleMedia(host: "media-only.fixture.bilivideo.com")
            let bridge = makeFixtureBridge(
                FixtureRangeTransport(
                    media: fixture.media
                )
            )

            let prepared = try await bridge.prepare(
                videos: [fixture.video],
                audioTracks: [makeSelectedAudioTrack(representation: fixture.audio)],
                headers: [:],
                subtitleSource: NativeSubtitleSource(
                    useCase: SubtitleUseCase(
                        repository: catalog.repository,
                        reportAuthenticationInvalidation: {}
                    ),
                    identity: PlaybackItemIdentity(bvid: "BV1MediaOnly", cid: 303)
                )
            )
            defer { prepared.stop() }
            let master = try await fetchText(prepared.url)
            let localizedNames = try await localizedRenditionNames(
                besideMaster: prepared.url
            )

            #expect(master.contains("#EXT-X-STREAM-INF:"))
            #expect(!master.contains("TYPE=SUBTITLES"))
            #expect(localizedNames["原声"]?["en"] == "Original audio")
        }

        @Test
        func subtitleCatalogGraceDoesNotWaitForNoncooperativeRepository() async throws {
            let fixture = try makeSimpleMedia(host: "subtitle-timeout.fixture.bilivideo.com")
            let repository = FixtureSubtitleRepository(
                catalog: .heldUntilReleased([
                    SubtitleTrack(
                        id: "late",
                        languageCode: "zh",
                        displayName: "中文",
                        kind: .standard
                    )
                ])
            )
            let transport = FixtureRangeTransport(media: fixture.media)
            let bridge = DASHToHLSBridge(
                rangeClient: HTTPRangeClient(streamer: transport),
                serverFactory: { LoopbackPlaybackServer(rangeStreamer: transport) }
            )
            let source = NativeSubtitleSource(
                useCase: SubtitleUseCase(
                    repository: repository,
                    reportAuthenticationInvalidation: {}
                ),
                identity: PlaybackItemIdentity(
                    bvid: "BV1SubtitleTimeout",
                    cid: 305
                )
            )
            let prepareTask = Task {
                try await bridge.prepare(
                    videos: [fixture.video],
                    audioTracks: [makeSelectedAudioTrack(representation: fixture.audio)],
                    headers: [:],
                    subtitleSource: source
                )
            }
            await repository.waitForTrackRequests(1)
            let prepared = try await prepareTask.value
            defer { prepared.stop() }
            await repository.releaseTracks()

            let master = try await fetchText(prepared.url)
            #expect(!master.contains("TYPE=SUBTITLES"))
        }
    }
}

/// 两种不可用的原生字幕目录：拉取失败，或标签不安全／归一化后重名。
enum UnusableNativeSubtitleCatalog: CaseIterable, Sendable {
    case failing
    case unsafeLabels

    var repository: any SubtitleRepository {
        switch self {
        case .failing:
            FixtureSubtitleRepository(catalog: .failure)
        case .unsafeLabels:
            FixtureSubtitleRepository(
                catalog: .tracks([
                    SubtitleTrack(
                        id: "unsafe",
                        languageCode: "unknown",
                        displayName: "unsafe\\label",
                        kind: .unknown
                    ),
                    SubtitleTrack(
                        id: "authored-duplicate-label",
                        languageCode: "zh",
                        displayName: "中文（AI）",
                        kind: .standard
                    ),
                    SubtitleTrack(
                        id: "automatic-duplicate-label",
                        languageCode: "ai-zh",
                        displayName: "中文",
                        kind: .automatic
                    )
                ])
            )
        }
    }
}
