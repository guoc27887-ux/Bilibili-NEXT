import Foundation

/// Slow streams may still be making useful progress. Audio alone cannot keep a
/// stalled video alive, and continuous tiny reads cannot postpone recovery forever.
struct PlaybackProgressDeadline {
  private let began: Duration
  private var lastProgress: Duration
  private var videoBytes = 0
  private var mediaTime: Double = 0
  init(now: Duration = .zero) { began = now; lastProgress = now }
  mutating func expired(now: Duration, videoBytes: Int, mediaTime: Double = 0) -> Bool {
    if videoBytes > self.videoBytes || (mediaTime.isFinite && mediaTime > self.mediaTime + 0.1) {
      lastProgress = now
    }
    self.videoBytes = max(self.videoBytes, videoBytes)
    if mediaTime.isFinite { self.mediaTime = max(self.mediaTime, mediaTime) }
    return now - began >= .seconds(45) || now - lastProgress >= .seconds(12)
  }
}
