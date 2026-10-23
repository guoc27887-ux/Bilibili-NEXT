import SwiftUI

/// Each visit owns its comments and reading position; the AVPlayer remains shared.
@MainActor @Observable final class MobileVideoVisit: Identifiable {
  let id = UUID()
  let bvid: String
  var detail: Detail?
  var cid: Int?
  var resume: PlaybackResume?
  var queue: [PlaybackQueueItem] = []
  var comments = Comments()
  var section = 0
  var scroll = ScrollPosition(y: 0)
  var local: SavedDownload?
  init(bvid: String, cid: Int? = nil, local: SavedDownload? = nil) {
    self.bvid = bvid
    self.cid = cid
    self.local = local
  }
}

enum MobilePlayerRoute: Hashable {
  case video(UUID)
  case profile(Int)
}

@MainActor @Observable final class MobilePlayerNavigation {
  var path: [MobilePlayerRoute] = []
  var root: MobileVideoVisit?
  var visits: [UUID: MobileVideoVisit] = [:]
  var active: UUID?
  var current: MobileVideoVisit? { active.flatMap { visits[$0] } }
  var visibleVideo: MobileVideoVisit? {
    for route in path.reversed() {
      if case .video(let id) = route { return visits[id] }
    }
    return root
  }
  func reset() {
    for visit in visits.values { visit.comments.stop() }
    path = []
    root = nil
    visits = [:]
    active = nil
  }
  func prune() {
    let retained = Set(
      path.compactMap { route -> UUID? in
        if case .video(let id) = route { return id }
        return nil
      } + [root?.id].compactMap { $0 })
    for id in Array(visits.keys) where !retained.contains(id) {
      visits.removeValue(forKey: id)?.comments.stop()
    }
  }
}

private struct PlayerNavigationKey: EnvironmentKey {
  static let defaultValue = false
}
extension EnvironmentValues {
  var insideMobilePlayer: Bool {
    get { self[PlayerNavigationKey.self] }
    set { self[PlayerNavigationKey.self] = newValue }
  }
}

struct MobileProfileLink<Label: View>: View {
  let store: Store
  let mid: Int
  @ViewBuilder let label: () -> Label
  @Environment(\.insideMobilePlayer) private var insidePlayer
  var body: some View {
    if insidePlayer {
      NavigationLink(value: MobilePlayerRoute.profile(mid), label: label)
    } else {
      NavigationLink {
        MobileProfile(store: store, mid: mid)
      } label: {
        label()
      }
    }
  }
}

struct MobilePlayerPage: View {
  @Bindable var store: Store
  @State private var fallback = MobileVideoVisit(bvid: "")
  var body: some View {
    @Bindable var navigation = store.playerNavigation
    NavigationStack(path: $navigation.path) {
      Group {
        if let root = navigation.root {
          MobilePlayerContent(store: store, visit: root)
        } else {
          MobilePlayerContent(store: store, visit: fallback)
        }
      }
      .navigationDestination(for: MobilePlayerRoute.self) { route in
        switch route {
        case .video(let id):
          if let visit = navigation.visits[id] { MobilePlayerContent(store: store, visit: visit) }
        case .profile(let mid):
          MobileProfile(store: store, mid: mid)
        }
      }
    }
    .sheet(isPresented: $store.showLogin, onDismiss: { store.closeLogin() }) {
      MobileLogin(store: store)
    }
    .sheet(item: $store.webTarget) { MobileWebPage(store: store, target: $0) }
    .environment(\.insideMobilePlayer, true)
    .onChange(of: navigation.path) { store.restorePlayerRoute() }
  }
}
