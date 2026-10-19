import AVFoundation

// A second native path for DASH codecs that AVPlayer's HLS demuxer rejects.
// The composition references the same bounded loopback sources; it does not export a file.
enum NativeComposition {
  static func make(video: URL, audio: URL) async throws -> AVComposition {
    let videoAsset = AVURLAsset(url: video)
    let audioAsset = AVURLAsset(url: audio)
    async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
    async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
    async let videoDuration = videoAsset.load(.duration)
    async let audioDuration = audioAsset.load(.duration)
    let (v, a, vd, ad) = try await (videoTracks, audioTracks, videoDuration, audioDuration)
    guard let vt = v.first, let at = a.first, vd.seconds.isFinite, vd.seconds > 0,
      ad.seconds.isFinite, ad.seconds > 0
    else { throw BiliError(text: "此视频流无法合轨播放") }
    let composition = AVMutableComposition()
    guard
      let videoTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let audioTrack = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { throw BiliError(text: "无法创建系统播放轨道") }
    try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
    try audioTrack.insertTimeRange(
      CMTimeRange(start: .zero, duration: CMTimeMinimum(vd, ad)), of: at, at: .zero)
    return composition.copy() as! AVComposition
  }
}
