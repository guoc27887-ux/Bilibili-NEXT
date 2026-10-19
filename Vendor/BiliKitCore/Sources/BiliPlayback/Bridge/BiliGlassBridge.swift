import BiliModels
import BiliNetworking
import Foundation
// BiliGlass adapter: expose the existing validated bridge without the upstream UI/engine.
extension DASHToHLSBridge {
    public init(mediaStreamer: any HTTPRangeStreaming) {
        self.init(rangeClient: HTTPRangeClient(streamer: mediaStreamer), serverFactory: { LoopbackPlaybackServer(rangeStreamer: mediaStreamer) })
    }

    public func prepare(video: MediaRepresentation, audio: MediaRepresentation, headers: [String: String], start: Double? = nil) async throws -> PreparedPlaybackAsset {
        let track = PlaybackAudioTrack.original(representations: [audio], loudnessMetadata: nil)
        return try await prepare(videos: [video], audioTracks: [SelectedPlaybackAudioTrack(track: track, representation: audio)], headers: headers, subtitleSource: nil, startPositionSeconds: start)
    }
}
