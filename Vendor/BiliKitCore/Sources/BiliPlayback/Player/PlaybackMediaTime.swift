@preconcurrency import AVFoundation

extension AVPlayerEngine {
    static func validSeconds(_ time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// Progressive MP4 使用音视频轨道实际 timeRange 的最晚样本边界，不用服务端 length 减固定 tolerance。
    ///
    /// 空轨、无效时间或零时长保持系统默认结束语义。
    package static func lastPresentableMediaEndTime(
        in asset: AVAsset
    ) async throws -> CMTime? {
        let tracks = try await asset.load(.tracks).filter {
            $0.mediaType == .video || $0.mediaType == .audio
        }
        var latest: CMTime?
        for track in tracks {
            let timeRange = try await track.load(.timeRange)
            let end = CMTimeRangeGetEnd(timeRange)
            guard let seconds = validSeconds(end), seconds > 0 else { continue }
            if latest.map({ CMTimeCompare(end, $0) > 0 }) ?? true {
                latest = end
            }
        }
        return latest
    }
}
