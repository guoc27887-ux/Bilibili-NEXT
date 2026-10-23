import SwiftUI

struct NativeInboxPage: View {
  @Bindable var store: Store
  @State private var tab = 0
  @State private var query = ""
  @State private var imageDrafts: [String: URL] = [:]
  var body: some View {
    @Bindable var inbox = store.inbox
    VStack(spacing: 16) {
      HStack {
        Text("消息").font(.title2.bold())
        Spacer()
        Picker("消息分类", selection: $tab) {
          Text("私信").tag(0)
          Text("回复我的").tag(1)
          Text("@ 我的").tag(2)
          Text("收到的赞").tag(3)
          Text("系统通知").tag(4)
        }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 500)
      }.padding(18).floatingGlass(22)
      if store.account == nil {
        ContentUnavailableView {
          Label("登录后查看消息", systemImage: "envelope")
        } actions: {
          Button("登录") { store.login() }.buttonStyle(.glass)
        }
      } else if [1, 2, 3].contains(tab) {
        NativeNotificationsPage(store: store, kind: tab)
      } else {
        HStack(spacing: 16) {
          conversationList.frame(width: 245)
          conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }.task(id: String(store.account?.mid ?? 0) + ":" + String(tab == 4)) {
      guard store.account != nil else { return }
      await inbox.load(api: store.api, systemOnly: tab == 4)
    }
  }
  private var conversationList: some View {
    let inbox = store.inbox
    return VStack(spacing: 12) {
      HStack {
        TextField("搜索会话", text: $query).textFieldStyle(.plain)
        Button {
          Task { await inbox.load(api: store.api, systemOnly: tab == 4) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).help("刷新消息")
      }.padding(13).appGlass(14).padding(.horizontal, 12)
        .padding(.top, 12)
      if let error = inbox.error {
        Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
      }
      ScrollView {
        LazyVStack(spacing: 5) {
          ForEach(
            inbox.conversations.filter {
              (tab != 4 || $0.system)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
            }
          ) { row in
            Button {
              inbox.select(row)
            } label: {
              HStack(alignment: .top, spacing: 10) {
                Thumbnail(url: row.face, mode: .fill, placeholder: "person.crop.circle.fill").frame(
                  width: 36, height: 36
                ).clipShape(
                  Circle())
                VStack(alignment: .leading, spacing: 5) {
                  HStack {
                    Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 1)
                    if row.unread > 0 {
                      Text(row.unread > 99 ? "99+" : String(row.unread)).font(.caption2)
                        .foregroundStyle(.white).padding(4).background(biliPink, in: .capsule)
                    }
                  }
                  Text(row.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .multilineTextAlignment(.leading)
                }
              }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  inbox.selected?.id == row.id ? biliPink.opacity(0.16) : .clear,
                  in: .rect(cornerRadius: 14))
            }.buttonStyle(.plain)
          }
          if inbox.loading {
            ProgressView().controlSize(.small).padding(12)
          } else if inbox.hasMore {
            Button("加载更多会话") {
              Task { await inbox.load(api: store.api, more: true, systemOnly: tab == 4) }
            }.buttonStyle(.glass).padding(12)
          }
        }.padding(.horizontal, 8).padding(.bottom, 12)
      }
    }.floatingGlass(22).clipShape(RoundedRectangle(cornerRadius: 22))
  }
  @ViewBuilder private var conversation: some View {
    let inbox = store.inbox
    if let selected = inbox.selected {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Button {
            store.showProfile(selected.mid)
          } label: {
            HStack {
              Thumbnail(url: selected.face, mode: .fill, placeholder: "person.crop.circle.fill")
                .frame(width: 30, height: 30).clipShape(
                  Circle())
              Text(selected.name).font(.headline)
            }
          }.buttonStyle(.plain)
          Spacer()
          Button {
            Task { await inbox.loadMessages(api: store.api) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }.buttonStyle(.glass).help("刷新会话")
        }.padding(16)
        Divider().padding(.horizontal, 16)
        ConversationTimeline(store: store) { message in
          messageBubble(message, own: message.sender == store.account?.mid)
        }.id(selected.id)
        if let error = inbox.messageError {
          HStack {
            Text(error).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("验证登录") {
              store.webTarget = WebTarget(
                url: URL(string: "https://message.bilibili.com/#/whisper")!, title: "消息验证")
            }.buttonStyle(.glass)
          }.padding(12)
        }
        Divider().padding(.horizontal, 16)
        HStack {
          EmojiPicker(api: store.api) { emote in inbox.emotes[emote.token] = emote; inbox.drafts[selected.id, default: ""] += emote.token }
          Button { if let url = ImageAttachment.choose().first { imageDrafts[selected.id] = url } } label: { Image(systemName: "photo.badge.plus") }.buttonStyle(.glass).help("发送图片").accessibilityLabel("添加私信图片")
          if let image = imageDrafts[selected.id] {
            Text(image.lastPathComponent).font(.caption).lineLimit(1)
            Button("取消图片") { imageDrafts[selected.id] = nil }.buttonStyle(.plain)
            Button("发送图片") { Task { if let account = store.account, await inbox.sendImage(image, api: store.api, account: account) { imageDrafts[selected.id] = nil } } }.buttonStyle(.glassProminent)
          }
          Spacer()
        }.padding(.horizontal, 14).padding(.top, 10).disabled(inbox.sending)
        HStack(alignment: .bottom, spacing: 12) {
          TextField(
            "发送私信",
            text: Binding(
              get: { inbox.drafts[selected.id] ?? "" }, set: { inbox.drafts[selected.id] = $0 }),
            axis: .vertical
          )
          .lineLimit(2...6).textFieldStyle(.plain).padding(12).appGlass(16)
          Button(inbox.sending ? "发送中" : "发送") {
            if let account = store.account {
              Task { await inbox.send(api: store.api, account: account) }
            }
          }
          .buttonStyle(.glassProminent).disabled(
            inbox.sending
              || (inbox.drafts[selected.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
          )
        }.padding(14)
      }.floatingGlass(22).clipShape(RoundedRectangle(cornerRadius: 22)).task(id: selected.id) {
        await inbox.loadMessages(api: store.api)
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          await inbox.loadMessages(api: store.api)
        }
      }
    } else {
      ContentUnavailableView("选择一个会话", systemImage: "bubble.left.and.bubble.right").frame(
        maxWidth: .infinity, maxHeight: .infinity
      ).floatingGlass(22)
    }
  }
  @ViewBuilder private func messageBubble(_ message: PrivateMessage, own: Bool) -> some View {
    if message.isNotice || message.retracted {
      Text(message.text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .textSelection(.enabled).padding(.horizontal, 24).padding(.vertical, 8).frame(maxWidth: .infinity)
    } else {
    HStack {
      if own { Spacer(minLength: 50) }
      VStack(alignment: .leading, spacing: 8) {
        if let image = message.image {
          Button { store.imageGallery = ImageGalleryTarget(urls: [image], selected: 0) } label: {
            Thumbnail(url: image, mode: .fit).frame(width: 220, height: 180).clipShape(
              RoundedRectangle(cornerRadius: 10))
          }.buttonStyle(.plain).help("查看图片")
        }
        if let share = message.share {
          MessageShareCard(share: share, store: store)
        } else {
        CommentText(content: CommentTextContent(message: message.text, emotes: store.inbox.emotes), copyTitle: "复制消息").foregroundStyle(
          message.retracted ? .secondary : .primary
        ).fixedSize(horizontal: false, vertical: true)
        if let bvid = message.video {
          Button("播放视频") { store.open(bvid) }.buttonStyle(.glass)
        } else if let link = message.link, message.image == nil {
          Link("查看详情", destination: link).font(.caption)
        }
        }
        Text(message.date.formatted(AppDateFormat.timestamp)).font(.caption2)
          .foregroundStyle(.secondary)
      }.padding(14).appGlass(18, tint: own ? biliPink.opacity(0.12) : .clear)
        .contextMenu {
          Button("复制消息") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
          if let account = store.account, inboxCanRecall(message, accountID: account.mid) {
            Button("撤回") { Task { await store.inbox.recall(message, api: store.api, account: account) } }.disabled(store.inbox.sending)
          }
        }
      if !own { Spacer(minLength: 50) }
    }
    }
  }
  private func inboxCanRecall(_ message: PrivateMessage, accountID: Int) -> Bool { store.inbox.canRecall(message, accountID: accountID) }
}

struct NativeNotificationsPage: View {
  @Bindable var store: Store
  let kind: Int
  @State private var rows: [NativeNotice] = []
  @State private var cursor: [String: Any] = [:]
  @State private var hasMore = false
  @State private var loading = false
  @State private var error: String?
  @State private var identity = UUID()
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        if let error { ErrorBanner(text: error) { Task { await load(reset: true) } } }
        ForEach(rows) { notice in
          HStack(alignment: .top, spacing: 14) {
            Button {
              store.showProfile(notice.mid)
            } label: {
              Thumbnail(url: notice.face, mode: .fill, placeholder: "person.crop.circle.fill")
                .frame(width: 38, height: 38).clipShape(
                  Circle())
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 10) {
              Text(notice.name).font(.headline)
              Text(notice.text).textSelection(.enabled)
              if !notice.quote.isEmpty {
                Text(notice.quote).font(.callout).foregroundStyle(.secondary).lineLimit(4)
              }
              HStack {
                Text(notice.date.formatted(AppDateFormat.timestamp)).font(.caption)
                  .foregroundStyle(.secondary)
                Spacer()
                if let url = notice.url {
                  Button("查看原内容") {
                    if let bvid = videoID(url.absoluteString) {
                      store.open(bvid)
                    } else {
                      NSWorkspace.shared.open(url)
                    }
                  }.buttonStyle(.glass)
                }
              }
            }
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading).floatingGlass(22)
        }
        if loading {
          ProgressView().frame(maxWidth: .infinity).padding(20)
        } else if hasMore {
          Button("加载更多") { Task { await load(reset: false) } }.buttonStyle(.glass).frame(
            maxWidth: .infinity)
        } else if rows.isEmpty && error == nil {
          ContentUnavailableView("暂无消息", systemImage: "bell").frame(maxWidth: .infinity)
        }
      }.padding(AppLayout.pageInset)
    }.task(id: kind) { await load(reset: true) }
  }
  private func load(reset: Bool) async {
    if reset {
      identity = UUID()
      rows = []
      cursor = [:]
    } else if loading {
      return
    }
    let token = identity
    loading = true
    error = nil
    defer { if token == identity { loading = false } }
    do {
      let endpoint = kind == 1 ? "reply" : kind == 2 ? "at" : "like"
      var query = ["platform": "web", "mobi_app": "web"]
      if !reset {
        if let id = cursor["id"] { query["id"] = String(describing: id) }
        if let time = cursor["time"] { query[endpoint + "_time"] = String(describing: time) }
      }
      let data = try await store.api.request("/x/msgfeed/" + endpoint, query)
      try Task.checkCancellation()
      guard token == identity else { return }
      let total = data["total"] as? [String: Any] ?? data
      let latest = data["latest"] as? [String: Any] ?? [:]
      let raw =
        (reset ? latest["items"] as? [[String: Any]] ?? [] : [])
        + (total["items"] as? [[String: Any]] ?? [])
      var ids = Set(rows.map(\.id))
      rows += raw.compactMap(NativeNotice.parse).filter { ids.insert($0.id).inserted }
      cursor = total["cursor"] as? [String: Any] ?? [:]
      hasMore = cursor["is_end"] as? Bool == false
    } catch {
      if token == identity && !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
