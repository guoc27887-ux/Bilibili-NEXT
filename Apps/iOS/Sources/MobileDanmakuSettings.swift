import SwiftUI

struct MobileDanmakuSettings: View {
  var presentedAsSheet = true
  @AppStorage("danmakuEnabled") private var enabled = true
  @AppStorage("danmakuScale") private var scale = 1.0
  @AppStorage("danmakuOpacity") private var opacity = 0.85
  @AppStorage("danmakuArea") private var area = 0.5
  @AppStorage("danmakuDuration") private var duration = 8.0
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Group {
      if presentedAsSheet {
        NavigationStack { settings.toolbar { Button("完成") { dismiss() } } }
      } else {
        settings
      }
    }
  }
  private var settings: some View {
    Form {
      Section("显示") {
        Toggle("显示弹幕", isOn: $enabled)
        VStack(alignment: .leading) {
          Text("文字大小 \(scale.formatted(.number.precision(.fractionLength(1))))×")
          Slider(value: $scale, in: 0.5...2, step: 0.1).accessibilityLabel("弹幕文字大小")
        }
        VStack(alignment: .leading) {
          Text("不透明度 \(Int(opacity*100))%")
          Slider(value: $opacity, in: 0.1...1).accessibilityLabel("弹幕不透明度")
        }
        VStack(alignment: .leading) {
          Text("显示区域 \(Int(area*100))%")
          Slider(value: $area, in: 0.2...1).accessibilityLabel("弹幕显示区域")
        }
        VStack(alignment: .leading) {
          Text("滚动时长 \(Int(duration)) 秒")
          Slider(value: $duration, in: 3...15, step: 1).accessibilityLabel("弹幕滚动时长")
        }
      }
      Section("过滤") { DanmakuFilteringControls() }
    }.navigationTitle("弹幕设置").navigationBarTitleDisplayMode(.inline)
  }
}
