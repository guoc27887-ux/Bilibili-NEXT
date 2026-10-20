import SwiftUI

struct AccountHistoryEntry: Identifiable {
  var id: String { "\(video.bvid):\(cid)" }
  let video: Video
  let cid: Int
  let progress: Int
  let viewedAt: Date
  let part: String
  static func parse(_ json: [String: Any]) -> Self? {
    let history = json["history"] as? [String: Any] ?? [:]
    guard history["business"] as? String == "archive",
      let bvid = history["bvid"] as? String, videoID(bvid) == bvid else { return nil }
    return Self(video: Video(bvid: bvid, title: cleanTitle(json["title"] as? String ?? "视频"),
      cover: json["cover"] as? String ?? "", author: json["author_name"] as? String ?? "",
      duration: json["duration"] as? Int ?? 0, views: 0),
      cid: history["cid"] as? Int ?? 0, progress: json["progress"] as? Int ?? 0,
      viewedAt: Date(timeIntervalSince1970: (json["view_at"] as? NSNumber)?.doubleValue ?? 0),
      part: history["part"] as? String ?? "")
  }
}

@MainActor @Observable final class AccountHistory {
  var items: [AccountHistoryEntry] = []
  var loading = false
  var hasMore = true
  var error: String?
  private var cursor: [String: String] = [:]
  private var generation = UUID()
  private var owner: String?
  private var loaded = false
  func reset() {
    generation = UUID(); items = []; cursor = [:]; owner = nil
    loading = false; hasMore = true; loaded = false; error = nil
  }
  func load(api: API, refresh: Bool = false) async {
    let currentOwner = api.cookies["DedeUserID"] ?? (api.signedIn ? "signed-in" : "guest")
    if currentOwner != owner { reset(); owner = currentOwner }
    guard api.signedIn else { error = "登录后查看账号历史"; return }
    if refresh { generation = UUID(); loading = false }
    guard !loading, refresh || hasMore else { return }
    let token = generation
    let authentication = api.authenticationGeneration
    let previous = refresh ? [:] : cursor
    var query = previous
    query["type"] = "archive"; query["ps"] = "30"
    loading = true; error = nil
    do {
      let data = try await api.request("/x/web-interface/history/cursor", query)
      try Task.checkCancellation()
      guard token == generation else { return }
      guard authentication == api.authenticationGeneration else { throw CancellationError() }
      let list = data["list"] as? [[String: Any]] ?? []
      let parsed = list.compactMap(AccountHistoryEntry.parse)
      var seen = Set(refresh ? [] : items.map(\.id))
      let unique = parsed.filter { seen.insert($0.id).inserted }
      items = refresh ? unique : items + unique
      let raw = data["cursor"] as? [String: Any] ?? [:]
      let next = ["max": String((raw["max"] as? NSNumber)?.int64Value ?? 0),
        "view_at": String((raw["view_at"] as? NSNumber)?.int64Value ?? 0),
        "business": raw["business"] as? String ?? ""]
      // Even an unrenderable/deleted item advances the server cursor.
      hasMore = !list.isEmpty && next != previous && next["max"] != "0"
      cursor = next; loaded = true; loading = false
    } catch {
      guard token == generation else { return }
      loading = false
      if !(error is CancellationError) { self.error = error.localizedDescription }
    }
  }
  func loadIfNeeded(api: API) async {
    let currentOwner = api.cookies["DedeUserID"] ?? (api.signedIn ? "signed-in" : "guest")
    if !loaded || owner != currentOwner { await load(api: api, refresh: true) }
  }
}

struct HistoryPage: View {
  @Bindable var store: Store
  @AppStorage("historySource") private var source = "account"
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Text("观看记录").font(AppLayout.pageTitle)
          Spacer()
          Picker("记录来源", selection: $source) {
            Text("账号历史").tag("account")
            Text("本机记录").tag("local")
          }.pickerStyle(.segmented).frame(width: 220)
          if source == "local" && !store.history.isEmpty {
            Button("清空本机记录") { store.history = []; store.persistHistory() }
          }
        }
        if source == "account" {
          if !store.api.signedIn {
            ContentUnavailableView {
              Label("登录后查看账号历史", systemImage: "clock.badge.person.crop")
            } actions: { Button("登录") { store.login() } }
          } else {
            Text("B 站账号中的视频观看记录").font(.callout).foregroundStyle(.secondary)
            GlassEffectContainer(spacing: 0) {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 390), spacing: 18)], spacing: 20) {
                ForEach(store.accountHistory.items) { entry in
                  Button { store.openHistory(entry) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                      VideoCard(video: entry.video, showsViews: false)
                      HStack {
                        Text(entry.viewedAt, format: AppDateFormat.timestamp)
                        Spacer()
                        Text(entry.progress < 0 ? "已看完" : "看到 \(String(format: "%d:%02d", max(0, entry.progress) / 60, max(0, entry.progress) % 60))")
                      }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }.contentShape(.rect(cornerRadius: 22))
                  }.buttonStyle(.plain)
                }
              }
            }
            if store.accountHistory.items.isEmpty && !store.accountHistory.loading && store.accountHistory.error == nil {
              ContentUnavailableView("暂无视频观看记录", systemImage: "clock")
            }
            LoadMoreFooter(loading: store.accountHistory.loading, hasMore: store.accountHistory.hasMore,
              error: store.accountHistory.error, count: store.accountHistory.items.count) {
                Task { await store.accountHistory.load(api: store.api) }
              }
          }
        } else {
          Text("仅保存在这台 Mac 上的播放记录").font(.callout).foregroundStyle(.secondary)
          if store.history.isEmpty { ContentUnavailableView("还没有本机记录", systemImage: "clock") }
          GlassEffectContainer(spacing: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 390), spacing: 18)], spacing: 20) {
              ForEach(store.history) { entry in
                Button { store.open(entry.video.bvid) } label: { VideoCard(video: entry.video) }.buttonStyle(.plain)
              }
            }
          }
        }
      }.padding(AppLayout.pageInset)
    }.task(id: source + "\(store.account?.mid ?? 0)") {
      if source == "account" { await store.accountHistory.loadIfNeeded(api: store.api) }
    }
  }
}
