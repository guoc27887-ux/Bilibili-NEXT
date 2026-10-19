import SwiftUI

final class AppLifecycle: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) { PlaybackTemporaryFiles.cleanup() }
  func applicationWillTerminate(_ notification: Notification) { PlaybackTemporaryFiles.cleanup(staleOnly: false) }
}

@main struct BiliGlassApp: App {
  @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
  @State private var store = Store()
  var body: some Scene {
    Window("Bilibili NEXT", id: "main") { RootView(store: store) }.defaultSize(width: 1260, height: 840)
      .windowStyle(.hiddenTitleBar)
      .commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .toolbar) {
          Button("搜索") {
            store.searchFocus += 1
          }.keyboardShortcut("f")
          Button("切换全屏播放") { store.fullscreen.toggle(store: store) }
            .keyboardShortcut("f", modifiers: [.command, .control]).disabled(!store.showPlayer)
          Button("刷新") {
            if store.showPlayer { store.playback.retry(api: store.api) } else { store.reload() }
          }.keyboardShortcut("r")
        }
      }
    Settings { PreferencesView() }
  }
}
