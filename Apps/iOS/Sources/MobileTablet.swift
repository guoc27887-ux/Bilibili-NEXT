import SwiftUI

private enum TabletDestination: String, CaseIterable, Identifiable {
  case recommend = "推荐"
  case popular = "热门"
  case regions = "分区"
  case dynamic = "关注动态"
  case messages = "消息"
  case history = "观看记录"
  case favorites = "收藏"
  case later = "稍后再看"
  case downloads = "下载"
  case profile = "我的主页"
  case search = "搜索"
  case settings = "设置"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .recommend: "house"
    case .popular: "flame"
    case .regions: "square.grid.2x2"
    case .dynamic: "person.2"
    case .messages: "bubble.left.and.bubble.right"
    case .history: "clock"
    case .favorites: "star"
    case .later: "text.badge.plus"
    case .downloads: "arrow.down.circle"
    case .profile: "person.crop.circle"
    case .search: "magnifyingglass"
    case .settings: "gearshape"
    }
  }
}

/// The iPad uses the same grouped sidebar and persistent search bar as the Mac app.
/// The content column stays mounted when the sidebar is hidden by window resizing.
struct MobileTabletRoot: View {
  @Bindable var store: Store
  @Environment(\.colorScheme) private var scheme
  @Environment(\.dynamicTypeSize) private var textSize
  @State private var selection = TabletDestination.recommend
  @State private var search = ""
  @State private var submittedSearch = ""
  @State private var showingSidebar = false
  @State private var loginAfterSidebar = false
  @State private var browsePath = NavigationPath()
  @FocusState private var searchFocused: Bool
  private var playing: Bool { store.showPlayer && !store.conversationPresented }

  var body: some View {
    GeometryReader { geometry in
      let expanded = geometry.size.width >= 900 && !textSize.isAccessibilitySize
      HStack(alignment: .top, spacing: expanded ? 20 : 0) {
        sidebar.frame(width: expanded ? 224 : 0)
          .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
          .clipped()
        VStack(spacing: 16) {
          topbar(expanded: expanded)
          ZStack {
            NavigationStack(path: $browsePath) { destination.id("\(selection):\(submittedSearch)") }
              .opacity(playing ? 0 : 1).allowsHitTesting(!playing).accessibilityHidden(playing)
            if playing { MobilePlayerPage(store: store) }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipShape(.rect(cornerRadius: 24))
          .overlay(alignment: .bottomTrailing) {
            if store.isPlaybackOpen && !store.showPlayer {
              MobileMiniPlayer(store: store)
                .padding(8).frame(maxWidth: expanded ? 420 : .infinity)
                .adaptiveGlassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(12)
            }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.padding(expanded ? 20 : 12)
        .background(backdrop.ignoresSafeArea())
        .sheet(
          isPresented: $showingSidebar,
          onDismiss: {
            if loginAfterSidebar {
              loginAfterSidebar = false
              store.login()
            }
          }
        ) {
          NavigationStack {
            sidebar.padding(20).background(backdrop.ignoresSafeArea())
              .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingSidebar = false } }
              }
          }.presentationDetents([.large])
        }
    }
    .onChange(of: playing) { _, visible in
      if !visible { store.playback.saveCurrentProgress() }
    }
    .onAppear {
      #if DEBUG
        if MobileUIFixture.enabled && ProcessInfo.processInfo.arguments.contains("--qa-inbox") {
          selection = .messages
        }
      #endif
    }
  }

  private var backdrop: some View {
    LinearGradient(
      colors: scheme == .dark
        ? [Color(red: 0.025, green: 0.05, blue: 0.09), Color(red: 0.13, green: 0.20, blue: 0.28)]
        : [Color(red: 0.94, green: 0.96, blue: 0.99), Color(red: 0.79, green: 0.85, blue: 0.92)],
      startPoint: .topLeading, endPoint: .bottomTrailing
    )
    .overlay(alignment: .bottomLeading) {
      RadialGradient(
        colors: [.cyan.opacity(0.13), .clear], center: .bottomLeading,
        startRadius: 0, endRadius: 600)
    }
  }

  private var sidebar: some View {
    VStack(spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "play.rectangle.fill").foregroundStyle(biliPink)
        Text("Bilibili NEXT").font(.headline)
        Spacer(minLength: 0)
      }.padding(.horizontal, 18).frame(height: 68)
        .adaptiveGlassEffect(.regular, in: .rect(cornerRadius: 24))
      ScrollView {
        VStack(spacing: 16) {
          group("浏览", items: [.recommend, .popular, .regions, .dynamic, .messages])
          group("资料库", items: [.history, .favorites, .later, .downloads, .profile])
        }
      }.scrollIndicators(.hidden)
      Button {
        if store.account == nil {
          if showingSidebar {
            loginAfterSidebar = true
            showingSidebar = false
          } else {
            store.login()
          }
        } else {
          select(.profile)
        }
      } label: {
        HStack(spacing: 10) {
          MobileAvatar(url: store.account?.face ?? "").frame(width: 32, height: 32).clipShape(
            .circle)
          Text(store.account?.name ?? (store.restoring ? "恢复登录中" : "登录哔哩哔哩"))
            .font(.subheadline).lineLimit(1)
          Spacer(minLength: 0)
        }.padding(.horizontal, 14).frame(minHeight: 58)
      }.buttonStyle(.plain).adaptiveGlassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .disabled(store.restoring && store.account == nil)
        .accessibilityIdentifier("tablet-account")
    }.accessibilityIdentifier("tablet-sidebar")
  }

  private func group(_ title: String, items: [TabletDestination]) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
      ForEach(items) { item in
        Button {
          select(item)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: item.symbol).frame(width: 20)
            Text(item.rawValue)
            if item == .messages { MessageUnreadBadge(count: store.messageUnread.counts.total) }
            Spacer(minLength: 0)
          }.font(.subheadline).padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              selection == item ? biliPink.opacity(0.19) : .clear,
              in: .rect(cornerRadius: 12)
            )
            .contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier("tablet-nav-\(item)")
          .accessibilityAddTraits(selection == item ? .isSelected : [])
      }
    }.padding(12).adaptiveGlassEffect(.regular, in: .rect(cornerRadius: 24))
  }

  private func topbar(expanded: Bool) -> some View {
    HStack(spacing: 12) {
      if !expanded {
        Button {
          showingSidebar = true
        } label: {
          Image(systemName: "sidebar.left").frame(width: 44, height: 44)
        }.accessibilityLabel("显示侧栏")
      }
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索视频或粘贴 BV 号", text: $search)
          .focused($searchFocused)
          .submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
          .onSubmit { submitSearch() }.accessibilityIdentifier("tablet-search")
      }.padding(.horizontal, 14).frame(minHeight: 44)
        .background(.thinMaterial, in: .capsule).frame(maxWidth: 520)
      Spacer(minLength: 0)
      Button {
        select(.settings)
      } label: {
        Image(systemName: "gearshape").frame(width: 44, height: 44)
      }.accessibilityLabel("设置")
    }.padding(.horizontal, 12).frame(minHeight: 68)
      .adaptiveGlassEffect(.regular, in: .rect(cornerRadius: 24))
  }

  @ViewBuilder private var destination: some View {
    switch selection {
    case .recommend: MobileHome(store: store, destination: 0)
    case .popular: MobileHome(store: store, destination: 1)
    case .regions: MobileHome(store: store, destination: 2)
    case .dynamic: MobileDynamics(store: store)
    case .messages: MobileInbox(store: store)
    case .history: MobileHistory(store: store)
    case .favorites: MobileFavorites(store: store)
    case .later:
      MobileVideoList(title: "稍后再看", store: store) { page in
        page == 1 ? try await store.api.later() : []
      }
    case .downloads: MobileDownloadsPage(store: store)
    case .profile: MobileAccount(store: store)
    case .settings: MobileSettings(store: store)
    case .search: MobileSearch(store: store, initialQuery: submittedSearch, showsSearchField: false)
    }
  }

  private func select(_ item: TabletDestination) {
    store.playback.saveCurrentProgress()
    store.showPlayer = false
    selection = item
    browsePath = NavigationPath()
    showingSidebar = false
  }

  private func submitSearch() {
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return }
    searchFocused = false
    if let bvid = videoID(term) {
      store.open(bvid)
    } else {
      submittedSearch = term
      select(.search)
    }
  }
}
