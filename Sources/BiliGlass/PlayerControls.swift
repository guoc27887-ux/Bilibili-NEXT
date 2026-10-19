import AVKit
import SwiftUI

/// A persistent native transport remains available when AVKit's floating HUD is hidden.
struct PlayerControls: View {
  let playback: Playback
  var fullscreen = false
  var toggleFullscreen: (() -> Void)?
  @State private var dragging = false
  @State private var position = 0.0
  var body: some View {
    Group {
      let player = playback.player
      let rawDuration = playback.durationSeconds
      let duration = rawDuration.isFinite ? max(0, rawDuration) : 0
      let rawTime = playback.positionSeconds
      let current = rawTime.isFinite ? max(0, rawTime) : 0
      HStack(spacing: 14) {
        Button { playback.focusPlayer(); playback.togglePlayback() } label: {
          Image(systemName: !playback.isPlaying ? "play.fill" : "pause.fill").frame(width: 20)
        }.buttonStyle(.glass).help(!playback.isPlaying ? "播放" : "暂停")
          .accessibilityLabel(!playback.isPlaying ? "播放" : "暂停")
        Text(clock(dragging ? position : current)).font(.caption.monospacedDigit()).frame(
          minWidth: 42)
        Slider(
          value: Binding(
            get: { dragging ? position : min(current, duration) },
            set: { position = $0 }), in: 0...max(1, duration)
        ) { editing in
          if editing { position = current }
          dragging = editing
          if !editing {
            playback.focusPlayer()
            player.seek(
              to: CMTime(seconds: min(duration, max(0, position)), preferredTimescale: 600),
              toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
          }
        }.labelsHidden().accessibilityLabel("播放进度").disabled(duration == 0 || playback.loading)
        Text(clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
        Slider(
          value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }),
          in: 0...1
        ).labelsHidden().accessibilityLabel("音量").frame(width: 90)
        if let toggleFullscreen {
          Button(action: toggleFullscreen) {
            Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
          }.buttonStyle(.glass).help(fullscreen ? "退出全屏" : "全屏播放")
            .accessibilityLabel(fullscreen ? "退出全屏" : "全屏播放")
        }
      }.padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
    }.onChange(of: playback.generation) { dragging = false }
  }
  private func clock(_ seconds: Double) -> String {
    let value = Int(max(0, seconds))
    return value >= 3600
      ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
      : String(format: "%d:%02d", value / 60, value % 60)
  }
}
