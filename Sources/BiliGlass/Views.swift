import AVKit
import SwiftUI

let biliPink = Color(red: 0.86, green: 0.24, blue: 0.43)
struct RootView: View {
  @Bindable var store: Store
  @FocusState private var searchFocused: Bool
  var body: some View {
    ZStack {
      if !store.fullscreen.isPresented { GlassBackdrop() }
      HStack(alignment: .top, spacing: 20) {
        GlassEffectContainer(spacing: 20) { sidebar }.frame(width: AppLayout.sidebarWidth)
        VStack(spacing: 16) {
          GlassEffectContainer { topbar }
          content.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(
            RoundedRectangle(cornerRadius: 24))
        }
      }.padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 22)
        .opacity(store.fullscreen.isPresented ? 0 : 1)
        .allowsHitTesting(!store.fullscreen.isPresented)
        .accessibilityHidden(store.fullscreen.isPresented)
      if store.fullscreen.isPresented {
        FullscreenPlayerContent(store: store, close: { store.fullscreen.close() }).ignoresSafeArea()
      }
    }
    .tint(biliPink).appAppearance().frame(minWidth: 1020, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
    .background { InitialWindowFocus().frame(width: 0, height: 0) }
    .containerBackground(.black, for: .window)
    .sheet(item: $store.imageGallery) { ImageGallery(target: $0) }
    .sheet(item: $store.webTarget) { target in
      VStack(spacing: 0) {
        HStack {
          Spacer()
          Button("完成") { store.webTarget = nil }
        }.padding(12)
        OfficialWebPanel(target: target, api: store.api)
      }.frame(minWidth: 1000, minHeight: 720)
    }
    .sheet(item: $store.profileTarget) { target in
      VStack {
        HStack {
          Spacer()
          Button("关闭") { store.profileTarget = nil }
        }.padding()
        ProfilePage(store: store, mid: target.id).padding(.horizontal, 16).padding(.bottom, 16)
      }.frame(minWidth: 900, minHeight: 650).background { GlassBackdrop() }
    }
    .overlay(alignment: .bottom) {
      if let text = store.interactionMessage {
        HStack {
          Text(text)
          Button {
            store.interactionMessage = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain)
        }.padding(14).glassEffect(.regular, in: .capsule).padding(20)
      }
    }
    .sheet(isPresented: $store.showLogin, onDismiss: { store.closeLogin() }) {
      LoginSheet(store: store)
    }
    .task {
      await store.start()
      let args = ProcessInfo.processInfo.arguments
      if let i = args.firstIndex(of: "--special-diagnostics"), args.indices.contains(i + 2) {
        await Diagnostics.special(store: store, output: URL(fileURLWithPath: args[i + 1]), bvid: args[i + 2])
      }
      if let i = args.firstIndex(of: "--native-diagnostics"), args.indices.contains(i + 1) {
        await Diagnostics.nativeFeatures(store: store, output: URL(fileURLWithPath: args[i + 1]))
      }
      if let i = args.firstIndex(of: "--community-diagnostics"), args.indices.contains(i + 1) {
        await Diagnostics.community(store: store, output: URL(fileURLWithPath: args[i + 1]))
      }
      if let i = args.firstIndex(of: "--video-diagnostics"), args.indices.contains(i + 2) {
        await Diagnostics.run(
          store: store, output: URL(fileURLWithPath: args[i + 1]), bvids: [args[i + 2]])
      }
      if let i = args.firstIndex(of: "--diagnostics"), args.indices.contains(i + 1) {
        await Diagnostics.run(store: store, output: URL(fileURLWithPath: args[i + 1]))
      }
    }
    .task {
      let args = ProcessInfo.processInfo.arguments
      if let i = args.firstIndex(of: "--state-output"), args.indices.contains(i + 1) {
        await Diagnostics.state(store: store, output: URL(fileURLWithPath: args[i + 1]))
      }
    }
    .onDisappear {
      store.playback.stop()
      store.danmaku.stop()
      store.comments.stop()
      store.downloads.persist()
    }
    .onChange(of: store.searchFocus) { searchFocused = true }
    .onChange(of: store.playerFocus) { searchFocused = false; store.playback.focusPlayer() }
    .onChange(of: store.navigationRevision) {
      if !store.showPlayer { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
    }
  }
  private var sidebar: some View {
    VStack(spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(biliPink)
        Text("Bilibili NEXT").font(.title3.weight(.semibold))
        Spacer(minLength: 0)
        SettingsLink { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("设置")
      }.padding(.horizontal, 18).frame(height: AppLayout.toolbarHeight).floatingGlass(AppLayout.panelRadius)
      ScrollView {
        VStack(spacing: 20) {
          navigationGroup("浏览", items: [.recommend, .popular, .dynamic, .messages])
          navigationGroup("资料库", items: [.history, .favorites, .later, .downloads, .profile, .web])
        }.padding(.vertical, 2)
      }.scrollIndicators(.hidden).clipped()
      accountButton
    }
  }
  private func navigationGroup(_ title: String, items: [Destination]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 12)
        .padding(.bottom, 8)
      ForEach(items) { d in
        Button {
          store.navigate(d)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: d.icon).frame(width: 20)
            Text(d.rawValue)
            Spacer(minLength: 0)
            if d == .downloads && store.downloads.activeCount > 0 {
              Text("\(store.downloads.activeCount)").font(.caption.monospacedDigit())
            }
          }.font(
            .system(
              size: 14, weight: store.destination == d && !store.showPlayer ? .semibold : .regular)
          )
          .padding(.horizontal, 12).padding(.vertical, 11).contentShape(
            RoundedRectangle(cornerRadius: 12)
          )
          .background(
            store.destination == d && !store.showPlayer ? biliPink.opacity(0.19) : .clear,
            in: .rect(cornerRadius: 12)
          )
          .foregroundStyle(store.destination == d && !store.showPlayer ? biliPink : .primary)
        }.buttonStyle(.plain)
      }
    }.padding(12).floatingGlass(24)
  }
  private var topbar: some View {
    HStack(spacing: 14) {
      if store.showPlayer {
        Button {
          store.showPlayer = false
          store.playback.stop()
          store.danmaku.stop()
          store.comments.stop()
        } label: {
          Image(systemName: "chevron.left")
        }.buttonStyle(.glass).help("返回")
      }
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索视频或粘贴 BV 号", text: $store.query).focused($searchFocused).textFieldStyle(.plain)
          .onSubmit { store.search() }
          .onExitCommand { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
        if !store.query.isEmpty {
          Button {
            store.clearSearch()
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }.buttonStyle(.plain).help("清除搜索")
        }
      }.padding(.horizontal, 15).frame(maxWidth: 520).frame(height: 44).appGlass(22)
      Spacer(minLength: 0)
      SettingsLink { Image(systemName: "gearshape") }.help("设置")
      Button {
        if store.showPlayer { store.playback.retry(api: store.api) } else { store.reload() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }.help("刷新")
    }.buttonStyle(.glass).padding(.horizontal, 12).frame(height: AppLayout.toolbarHeight).floatingGlass(AppLayout.panelRadius)
  }
  @ViewBuilder private var content: some View {
    if store.showPlayer {
      PlayerPage(store: store)
    } else {
      switch store.destination {
      case .recommend, .popular, .favorites, .later: browse
      case .dynamic: NativeDynamicsPage(store: store)
      case .profile:
        if let account = store.account {
          ProfilePage(store: store, mid: account.mid)
        } else {
          ContentUnavailableView {
            Label("登录后查看主页", systemImage: "person.crop.circle")
          } actions: {
            Button("登录") { store.login() }
          }
        }
      case .history: HistoryPage(store: store)
      case .downloads: DownloadPage(store: store)
      case .messages: NativeInboxPage(store: store)
      case .web: WebFunctionsPage(store: store)
      }
    }
  }
  private var accountButton: some View {
    Group {
      if let account = store.account {
        HStack(spacing: 10) {
          Button {
            store.navigate(.profile)
          } label: {
            HStack(spacing: 10) {
              Thumbnail(url: account.face, mode: .fill, placeholder: "person.crop.circle.fill")
                .frame(width: 32, height: 32).clipShape(
                  Circle())
              Text(account.name).lineLimit(1)
              Spacer(minLength: 0)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
          Menu {
            Button("我的主页") { store.navigate(.profile) }
            SettingsLink { Text("设置") }
            Button("退出登录", role: .destructive) { store.logout() }
          } label: {
            Image(systemName: "ellipsis")
          }
          .menuStyle(.borderlessButton).frame(width: 20)
        }.padding(12).frame(height: 58)
      } else if store.restoring {
        HStack {
          ProgressView().controlSize(.small)
          Text("恢复登录中").font(.callout)
        }.padding(10)
      } else {
        Button {
          store.login()
        } label: {
          HStack {
            Image(systemName: "person.crop.circle").font(.title2)
            Text("登录")
            Spacer()
            Image(systemName: "qrcode").foregroundStyle(.secondary)
          }.padding(10)
        }.buttonStyle(.plain)
      }
    }.frame(maxWidth: .infinity).frame(height: 58).floatingGlass(20)
  }
  private var browse: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .firstTextBaseline) {
          Text(store.activeQuery.isEmpty ? store.destination.rawValue : "搜索结果").font(
            .system(size: 28, weight: .bold))
          if !store.activeQuery.isEmpty { Text(store.activeQuery).foregroundStyle(.secondary) }
          Spacer()
          if store.busy { ProgressView().controlSize(.small) }
        }
        if store.destination == .favorites && !store.folders.isEmpty {
          Picker("收藏夹", selection: $store.selectedFolder) {
            ForEach(store.folders) { f in Text(f.title + "（\(f.count)）").tag(f.id) }
          }.pickerStyle(.menu).onChange(of: store.selectedFolder) {
            store.videos = []
            store.reload()
          }
        }
        if let error = store.error, store.videos.isEmpty { ErrorBanner(text: error) { store.reload() } }
        if store.videos.isEmpty && !store.busy && !store.restoring && store.error == nil {
          ContentUnavailableView(
            "没有找到视频", systemImage: "magnifyingglass", description: Text("换个关键词试试"))
        }
        videoGrid(store.videos)
        if !store.videos.isEmpty {
          LoadMoreFooter(loading: store.busy, hasMore: store.hasMore, error: store.error, count: store.videos.count) { store.more() }
        }
      }.padding(AppLayout.pageInset).padding(.vertical, 8)
    }.overlay { if store.busy && store.videos.isEmpty { ProgressView("正在加载") } }
  }
  private func videoGrid(_ videos: [Video]) -> some View {
    GlassEffectContainer(spacing: 0) {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 240, maximum: 390), spacing: 18)], alignment: .leading,
      spacing: 20
    ) {
      ForEach(videos) { video in
        Button {
          store.open(video.bvid)
        } label: {
          VideoCard(video: video)
        }.buttonStyle(.plain).contextMenu {
          Button("播放") { store.open(video.bvid) }
          Button("复制链接") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
              "https://www.bilibili.com/video/\(video.bvid)", forType: .string)
          }
          Link("在浏览器打开", destination: URL(string: "https://www.bilibili.com/video/\(video.bvid)")!)
        }
      }
    }
    }
  }
}
struct VideoCard: View {
  let video: Video
  var showsViews = true
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Thumbnail(url: video.cover, mode: .fill).aspectRatio(16 / 9, contentMode: .fit).clipShape(
        RoundedRectangle(cornerRadius: 12)
      ).overlay(alignment: .bottomTrailing) {
        Text(duration(video.duration)).font(.caption.monospacedDigit()).foregroundStyle(.white)
          .padding(.horizontal, 7).padding(.vertical, 4).background(
            .black.opacity(0.72), in: Capsule()
          ).padding(8)
      }
      Text(video.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
        .multilineTextAlignment(.leading).frame(height: 38, alignment: .topLeading).foregroundStyle(
          .primary)
      HStack(spacing: 6) {
        Text(video.author).lineLimit(1)
        Spacer(minLength: 2)
        if showsViews {
          Image(systemName: "play").font(.system(size: 9))
          Text(
          video.views >= 10000
            ? String(format: "%.1f万", Double(video.views) / 10000) : "\(video.views)")
        }
      }.font(.caption).foregroundStyle(.secondary)
    }.padding(12).floatingGlass(22).contentShape(RoundedRectangle(cornerRadius: 22)).cardHover()
  }
  private func duration(_ t: Int) -> String {
    t >= 3600
      ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
      : String(format: "%d:%02d", t / 60, t % 60)
  }
}
struct Thumbnail: View {
  let url: String
  let mode: ContentMode
  var placeholder = "play.rectangle"
  @State private var image: NSImage?
  var body: some View {
    GeometryReader { g in
      Group {
        if let image {
          Image(nsImage: image).resizable().aspectRatio(contentMode: mode)
        } else {
          Rectangle().fill(.quaternary).overlay {
            Image(systemName: placeholder).font(.title).foregroundStyle(.tertiary)
          }
        }
      }.frame(width: g.size.width, height: g.size.height).clipped()
    }.task(id: url) {
      image = nil
      let value =
        url.hasPrefix("//")
        ? "https:" + url : url.replacingOccurrences(of: "http://", with: "https://")
      guard let target = URL(string: value),
        let decoded = try? await ThumbnailCache.shared.thumbnail(target), !Task.isCancelled
      else { return }
      image = NSImage(cgImage: decoded, size: .zero)
    }.onDisappear { image = nil }
  }
}
struct ErrorBanner: View {
  let text: String
  let retry: () -> Void
  var body: some View {
    HStack {
      Image(systemName: "exclamationmark.circle")
      Text(text).textSelection(.enabled)
      Spacer()
      Button("重试", action: retry)
    }.padding(16).floatingGlass(18)
  }
}
struct PlayerPage: View {
  @Bindable var store: Store
  @State private var commentAnchor: Int?
  var body: some View {
    @Bindable var p = store.playback
    GeometryReader { viewport in
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ZStack {
          NativePlayer(playback: p, items: store.danmaku.items, enabled: store.danmaku.enabled, toggleFullscreen: { store.fullscreen.open(store: store) })
            .frame(height: max(270, min((min(viewport.size.width, 1280) - 40) * 9 / 16, viewport.size.height - 210)))
          PlaybackStatusOverlay(playback: p)
        }.background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
          .overlay(alignment: .top) {
            if p.isBoosting { Label(p.boostLabel, systemImage: "forward.fill").font(.callout).padding(10).glassEffect(.regular, in: .capsule).padding(16).colorScheme(.dark).allowsHitTesting(false) }
          }
          .overlay { PlaybackDetailsOverlay(playback: p) }
        PlayerControls(playback: p, toggleFullscreen: { store.fullscreen.open(store: store) })
        if let error = p.error {
          VStack(alignment: .leading, spacing: 10) {
            ErrorBanner(text: error) { p.retry(api: store.api) }

          }
        }
        HStack(spacing: 12) {
          if let s = p.streams {
            Menu {
              ForEach(Array(Set(s.videos.map(\.id))).sorted(by: >), id: \.self) { qn in
                Button {
                  p.selectQuality(qn, api: store.api)
                } label: {
                  if qn == p.selectedQuality {
                    Label(s.names[qn] ?? "\(qn)", systemImage: "checkmark")
                  } else {
                    Text(s.names[qn] ?? "\(qn)")
                  }
                }
              }
            } label: {
              Label(s.names[p.selectedQuality] ?? "清晰度", systemImage: "slider.horizontal.3")
            }
          }
          Menu {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
              Button("\(rate.formatted())×") { p.setSpeed(Float(rate)) }
            }
          } label: {
            Text("\(Double(p.speed).formatted())×")
          }
          if !p.actualSize.isEmpty {
            Text(p.actualSize + (p.sourceFormat.isEmpty ? "" : " · " + p.sourceFormat)).help(
              p.decodedFormat
            ).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
          Spacer()
          Button { p.showsDetails.toggle() } label: { Image(systemName: "waveform.path.ecg") }.help("播放详情").accessibilityLabel("播放详情")
          if let d = p.detail, p.streams != nil {
            Menu {
              Button("缓存到应用") {
                store.downloads.enqueue(
                  video: d.video, cid: p.selectedCID, qn: p.selectedQuality, api: store.api,
                  cached: true)
              }
              Button("下载到其他位置…") {
                store.downloads.enqueue(
                  video: d.video, cid: p.selectedCID, qn: p.selectedQuality, api: store.api,
                  cached: false)
              }
              Divider()
              Button("下载弹幕 XML…") {
                Task {
                  await store.downloads.saveDanmaku(
                    video: d.video, cid: p.selectedCID, api: store.api)
                }
              }
            } label: {
              Label("下载", systemImage: "arrow.down")
            }.disabled(p.loading)
          }
        }.buttonStyle(.glass).controlSize(.regular)
        if let d = p.detail {
          HStack {
            Text(d.video.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            Spacer()
          }
          if d.aid > 0 {
            VideoActionBar(store: store, detail: d)
            DanmakuComposer(store: store, aid: d.aid)
          }
          HStack {
            Button {
              store.showProfile(d.ownerID)
            } label: {
              Label(d.video.author, systemImage: "person.crop.circle")
            }.buttonStyle(.plain)
            Text(d.video.bvid)
            if let date = d.video.publishedAt {
              Text("发布于 " + date.formatted(AppDateFormat.timestamp))
                .help("发布时间 · 当前时区")
            }
          }.font(.callout).foregroundStyle(.secondary)
          if d.pages.count > 1 && !p.isOffline {
            Text("分集").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
              ForEach(d.pages) { page in
                Button {
                  p.selectPage(
                    page.id, api: store.api, resume: store.position(d.video.bvid, cid: page.id))
                } label: {
                  HStack {
                    Text("\(page.number)").foregroundStyle(.secondary)
                    Text(page.title).lineLimit(1)
                    Spacer()
                    if p.selectedCID == page.id {
                      Image(systemName: "waveform").foregroundStyle(biliPink)
                    }
                  }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.glass).disabled(p.loading)
              }
            }
          }
          if !d.description.isEmpty {
            Text(d.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
              .lineSpacing(5).padding(.top, 4)
          }
          Divider().padding(.vertical, 8)
          if d.aid > 0 { CommentsView(store: store, aid: d.aid).padding(.top, 8) }
        }
      }.padding(20).frame(maxWidth: 1280).frame(maxWidth: .infinity)
    }.scrollPosition(id: $commentAnchor, anchor: .top)
      .floatingGlass(24).clipShape(RoundedRectangle(cornerRadius: 24)).task(id: p.selectedCID) {
      if p.isOffline {
        store.danmaku.start(
          cid: p.selectedCID, api: store.api, player: p.player, localSidecar: p.localDanmaku)
      } else {
        store.danmaku.start(
          cid: p.selectedCID, aid: p.detail?.aid ?? 0, api: store.api, player: p.player)
      }
    }
    }
  }
}
struct LoginSheet: View {
  @Bindable var store: Store
  var body: some View {
    VStack(spacing: 20) {
      HStack {
        Text("登录哔哩哔哩").font(.title2.weight(.semibold))
        Spacer()
        Button {
          store.showLogin = false
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.glass).help("关闭")
      }
      ZStack {
        RoundedRectangle(cornerRadius: 16).fill(.white)
        if let image = store.qrImage {
          Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(16).opacity(
            store.loginExpired ? 0.15 : 1)
        }
        if store.qrImage == nil && !store.loginExpired { ProgressView() }
        if store.loginExpired { Button("刷新二维码") { store.refreshQR() }.buttonStyle(.glassProminent) }
      }.frame(width: 230, height: 230)
      Text(store.loginStatus).font(.callout).foregroundStyle(.secondary)
      Text("登录信息保存在 macOS 钥匙串").font(.caption).foregroundStyle(.tertiary)
    }.padding(28).frame(width: 380).background { GlassBackdrop() }
  }
}
