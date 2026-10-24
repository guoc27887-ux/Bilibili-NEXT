import AVFoundation
import AppKit
import BiliModels
import BiliNetworking
import CryptoKit
import Foundation
import SwiftUI
import Synchronization
import WebKit

@MainActor enum Diagnostics {
  /// Explicit QA only: read notification pages and keep counters/schema, never message bodies or credentials.
  static func messageReadCheck(store: Store, output: URL) async {
    func snapshot() -> [String: Any] {
      let counts = store.messageUnread.counts
      return ["reply": counts.replies, "at": counts.mentions, "like": counts.likes,
        "private": counts.privateMessages, "total": counts.total, "error": store.messageUnread.error ?? ""]
    }
    await store.messageUnread.refresh(api: store.api)
    var result: [String: Any] = ["before": snapshot()]
    for (index, endpoint) in ["reply", "at", "like"].enumerated() {
      do {
        let data = try await store.api.request("/x/msgfeed/" + endpoint, ["platform": "web", "mobi_app": "web"])
        let total = data["total"] as? [String: Any] ?? data
        let latest = data["latest"] as? [String: Any] ?? [:]
        let raw = (latest["items"] as? [[String: Any]] ?? []) + (total["items"] as? [[String: Any]] ?? [])
        let notices = raw.compactMap { NativeNotice.parse($0, kind: index + 1) }
        await store.messageUnread.refresh(api: store.api)
        result[endpoint] = ["loaded": notices.count, "after": snapshot(),
          "actions": Array(Set(notices.map(\.action))).sorted(),
          "itemKeys": Array(Set(raw.flatMap { ($0["item"] as? [String: Any] ?? [:]).keys })).sorted()]
      } catch { result[endpoint] = error.localizedDescription }
    }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output, options: .atomic)
    }
  }
  /// Opt-in check against an already-full video only. Never spend a test coin.
  static func fullCoinCheck(api: API, bvid: String, output: URL,
                            showChallenge: ((InteractionChallenge) -> Void)? = nil) async {
    var result: [String: Any] = ["bvid": bvid]
    do {
      let detail = try await api.detail(bvid)
      let before = try await api.videoRelation(detail.aid, bvid: bvid)
      let limit = detail.copyright == 2 ? 1 : 2
      result["beforeCoins"] = before.coins; result["limit"] = limit
      result["beforeLiked"] = before.liked; result["beforeFavorited"] = before.favorited
      result["requestVariant"] = api.appCoinAuthorization?.isValid(for: api.cookies["DedeUserID"]) == true
        ? "app-authorization" : "web-session"
      guard before.coins >= limit else { throw BiliError(text: "诊断已停止：视频尚未投满") }
      let arguments = ProcessInfo.processInfo.arguments
      if let i = arguments.firstIndex(of: "--coin-browser-reference-check"), arguments.indices.contains(i + 1) {
        result["comparison"] = try await compareBrowserCoinReference(api: api, detail: detail,
          file: URL(fileURLWithPath: arguments[i + 1]))
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--coin-web-ticket-check") {
        // Official web client protocol; this public SDK key is not an account credential.
        let timestamp = Int(Date().timeIntervalSince1970)
        let signature = HMAC<SHA256>.authenticationCode(for: Data("ts\(timestamp)".utf8),
          using: SymmetricKey(data: Data("XgwSnGZ1p".utf8))).map { String(format: "%02x", $0) }.joined()
        var url = URLComponents(string: "https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket")!
        url.queryItems = ["key_id": "ec02", "hexsign": signature, "context[ts]": String(timestamp),
          "csrf": api.cookies["bili_jct"] ?? ""].map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!); request.httpMethod = "POST"
        API.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue(api.cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        let auth = api.authenticationGeneration
        let (data, response) = try await api.session.data(for: request)
        guard auth == api.authenticationGeneration else { throw CancellationError() }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        result["ticketHTTPStatus"] = (response as? HTTPURLResponse)?.statusCode
        result["ticketCode"] = root?["code"]
        if root?["code"] as? Int == 0, let payload = root?["data"] as? [String: Any],
          let ticket = payload["ticket"] as? String, !ticket.isEmpty,
          let created = payload["created_at"] as? Int, let ttl = payload["ttl"] as? Int, ttl > 0 {
          api.cookies["bili_ticket"] = ticket
          api.cookies["bili_ticket_expires"] = String(created + ttl)
          result["ticketReady"] = true
        }
      }
      result["beforeBalance"] = try await api.request("/x/web-interface/nav")["money"]
      do {
        if ProcessInfo.processInfo.arguments.contains("--coin-web-context-check") {
          // Compare the official web form for a paused, not-started player.
          // This diagnostic still requires an already-full video above.
          result["requestVariant"] = "official-web-context"
          try await api.prepareVideoInteraction()
          let parameters = [
            "aid": String(detail.aid), "multiply": "1", "select_like": "0", "cross_domain": "true",
            "source": "web_normal", "ga": "1", "eab_x": "2", "ramval": "0",
            "spmid": "333.788.0.0", "from_spmid": "", "statistics": #"{"appId":100,"platform":5}"#,
          ]
          if ProcessInfo.processInfo.arguments.contains("--coin-browser-transport-check") {
            result["requestVariant"] = "browser-transport-with-web-context"
            let root = try await browserCoinRequest(api: api, bvid: bvid, parameters: parameters)
            result["browserHTTPStatus"] = root["httpStatus"]
            result["fullWebPage"] = root["fullPage"]
            let code = root["code"] as? Int ?? -1
            result["hasOfficialChallenge"] = ((root["data"] as? [String: Any])?["ga_data"] as? [String: Any]) != nil
            guard code == 0 else { throw BiliError(text: root["message"] as? String ?? "网页请求失败", code: code) }
          } else {
            _ = try await api.post("/x/web-interface/coin/add", parameters, videoBVID: bvid)
          }
        } else {
          _ = try await api.addVideoCoins(aid: detail.aid, bvid: bvid, amount: 1, alsoLike: false)
        }
        result["unexpectedSuccess"] = true
      } catch {
        result["code"] = (error as? BiliError)?.code
        result["message"] = error.localizedDescription
        if result["hasOfficialChallenge"] == nil { result["hasOfficialChallenge"] = (error as? BiliError)?.challenge != nil }
        if let challenge = (error as? BiliError)?.challenge,
          let payload = try? JSONSerialization.jsonObject(with: challenge.payload) as? [String: Any] {
          result["challengeFields"] = payload.keys.sorted()
          showChallenge?(challenge)
        }
      }
      let after = try await api.videoRelation(detail.aid, bvid: bvid)
      result["afterCoins"] = after.coins
      result["afterLiked"] = after.liked; result["afterFavorited"] = after.favorited
      result["afterBalance"] = try await api.request("/x/web-interface/nav")["money"]
      result["cookieNames"] = api.cookies.keys.sorted()
    } catch { result["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output, options: .atomic)
    }
  }
  /// Explicit local diagnostic only. Reference credentials stay in memory, are never
  /// installed in the app's vault, and can only test the same account's full video.
  private static func compareBrowserCoinReference(api: API, detail: Detail, file: URL) async throws -> [String: Any] {
    let data = try Data(contentsOf: file)
    guard data.count < 65_536,
      let reference = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let cookieReference = reference["cookies"] as? [String: String],
      cookieReference["DedeUserID"] == api.cookies["DedeUserID"],
      let string = reference["url"] as? String, let url = URL(string: string),
      url.scheme == "https", url.host == "api.bilibili.com", url.path == "/x/web-interface/coin/add",
      let bodyReference = reference["body"] as? [String: String],
      bodyReference["aid"] == String(detail.aid), bodyReference["multiply"] == "1",
      bodyReference["select_like"] == "0",
      let headers = reference["headers"] as? [String: String]
    else { throw BiliError(text: "浏览器对照文件不匹配，已停止") }
    let authentication = api.authenticationGeneration
    let browser = API(loadCredentials: false)
    browser.cookies = cookieReference
    var result: [String: Any] = ["cookieNames": cookieReference.keys.sorted(),
      "matchingCookieNames": api.cookies.keys.filter { cookieReference[$0] == api.cookies[$0] }.sorted()]
    let isolateSession = ProcessInfo.processInfo.arguments.contains("--coin-session-isolation")
    let nativeAuth = API(loadCredentials: false), browserAuth = API(loadCredentials: false)
    let authNames: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
    nativeAuth.cookies = cookieReference.filter { !authNames.contains($0.key) }
      .merging(api.cookies.filter { authNames.contains($0.key) }) { _, new in new }
    browserAuth.cookies = api.cookies.filter { !authNames.contains($0.key) }
      .merging(cookieReference.filter { authNames.contains($0.key) }) { _, new in new }
    let variants = isolateSession
      ? [("nativeAuthBrowserDevice", nativeAuth), ("browserAuthNativeRequest", browserAuth)]
      : [("nativeSession", api), ("browserSession", browser)]
    for (name, client) in variants {
      try Task.checkCancellation()
      guard api.authenticationGeneration == authentication else { throw CancellationError() }
      let relation = try await client.videoRelation(detail.aid, bvid: detail.video.bvid)
      guard relation.coins >= (detail.copyright == 2 ? 1 : 2) else { throw BiliError(text: "对照账号尚未投满，已停止") }
      let beforeBalance = try await client.request("/x/web-interface/nav")["money"]
      if name == "browserAuthNativeRequest" {
        var status: [String: Any] = [:]
        do {
          _ = try await client.addVideoCoins(aid: detail.aid, bvid: detail.video.bvid, amount: 1, alsoLike: false)
          status["code"] = 0
        } catch {
          status["code"] = (error as? BiliError)?.code ?? -1
          status["message"] = error.localizedDescription
        }
        status["beforeCoins"] = relation.coins
        status["afterCoins"] = try await client.videoRelation(detail.aid, bvid: detail.video.bvid).coins
        status["beforeBalance"] = beforeBalance
        status["afterBalance"] = try await client.request("/x/web-interface/nav")["money"]
        result[name] = status
        continue
      }
      var body = bodyReference
      body["csrf"] = client.cookies["bili_jct"]
      // The diagnostic has no active player; never replay captured watch time.
      body["eab_x"] = "2"; body["ramval"] = "0"
      var request = URLRequest(url: url); request.httpMethod = "POST"
      request.httpBody = API.formBody(body)
      for key in ["user-agent", "accept", "content-type", "origin", "referer", "accept-language"] {
        request.setValue(headers[key], forHTTPHeaderField: key)
      }
      request.setValue(client.cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
      let (data, response) = try await client.session.data(for: request)
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
      result[name] = ["httpStatus": (response as? HTTPURLResponse)?.statusCode ?? 0,
        "code": root["code"] ?? NSNull(), "message": root["message"] ?? NSNull(),
        "beforeCoins": relation.coins,
        "afterCoins": try await client.videoRelation(detail.aid, bvid: detail.video.bvid).coins,
        "beforeBalance": beforeBalance ?? NSNull(),
        "afterBalance": try await client.request("/x/web-interface/nav")["money"] ?? NSNull()]
    }
    return result
  }
  /// Called only after fullCoinCheck has verified that the video is already full.
  /// Compare the browser's normal network transport, without loading or solving a captcha.
  private static func browserCoinRequest(api: API, bvid: String, parameters: [String: String]) async throws -> [String: Any] {
    let authentication = api.authenticationGeneration
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WebSession.shared.dataStore
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.customUserAgent = API.userAgent
    await WebSession.shared.prepare(api: api)
    let fullPage = ProcessInfo.processInfo.arguments.contains("--coin-full-web-page-check")
    let videoURL = URL(string: "https://www.bilibili.com/video/\(bvid)/")!
    if fullPage { view.load(URLRequest(url: videoURL)) }
    else {
      view.loadHTMLString("<html><body><script>window.transportReady = true;</script></body></html>", baseURL: videoURL)
    }
    defer { view.stopLoading() }
    var ready = false
    for _ in 0..<100 {
      let predicate = fullPage
        ? "document.readyState === 'complete' && window.__INITIAL_STATE__?.videoData?.bvid === '\(bvid)' && !!window.player"
        : "window.transportReady === true"
      if (try? await view.evaluateJavaScript(predicate)) as? Bool == true { ready = true; break }
      try await Task.sleep(for: .milliseconds(fullPage ? 200 : 50))
    }
    try Task.checkCancellation()
    guard authentication == api.authenticationGeneration else { throw CancellationError() }
    guard ready else { throw BiliError(text: "完整官网页面未就绪，未发送投币请求") }
    var body = parameters
    body["csrf"] = api.cookies["bili_jct"]
    let value = try await view.callAsyncJavaScript("""
      if (fullPage) {
        const video = window.__INITIAL_STATE__?.videoData;
        if (!video || String(video.aid) !== parameters.aid) throw new Error('Video changed');
        parameters.eab_x = window.player.isPaused() ? '2' : '1';
        const actualTime = window.player.getMediaInfo()?.absolutePlayTime;
        if (Number.isFinite(actualTime)) parameters.ramval = String(actualTime);
        else delete parameters.ramval;
      }
      const response = await fetch('https://api.bilibili.com/x/web-interface/coin/add', {
        method:'POST', credentials:'include',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:new URLSearchParams(parameters), signal:AbortSignal.timeout(25000)
      });
      const root = await response.json();
      return {...root,httpStatus:response.status,fullPage};
      """, arguments: ["parameters": body, "fullPage": fullPage], in: nil, contentWorld: .page)
    guard authentication == api.authenticationGeneration,
      let root = value as? [String: Any] else { throw CancellationError() }
    return root
  }
  static func previewReadCheck(api: API, bvid: String, output: URL) async {
    var result: [String: Any] = ["bvid": bvid]
    do {
      let detail = try await api.detail(bvid)
      let data = try await api.request("/x/player/videoshot", ["aid": String(detail.aid), "cid": String(detail.pages.first?.id ?? 0), "index": "1"])
      result["metadata"] = data.filter { !["image", "index", "pvdata"].contains($0.key) }
      result["indexCount"] = (data["index"] as? [Any])?.count ?? 0
      let urls = (data["image"] as? [String] ?? []).compactMap(API.publicMediaURL)
      result["sheetCount"] = urls.count
      if let url = urls.first {
        do {
          let blob = try await ThumbnailCache.shared.data(url)
          result["bytes"] = blob.count
          if let source = CGImageSourceCreateWithData(blob as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            result["imageWidth"] = properties[kCGImagePropertyPixelWidth]
            result["imageHeight"] = properties[kCGImagePropertyPixelHeight]
            result["imageType"] = CGImageSourceGetType(source)
          }
          let image = try await PreviewSheets.shared.image(url)
          result["decodedWidth"] = image.width; result["decodedHeight"] = image.height
          result["decodedBytes"] = image.image.bytesPerRow * image.height
          let shots = try await api.previewShots(data: data, cid: detail.pages.first?.id ?? 0)
          result["resolvedIndexCount"] = shots.times.count
          result["indexPrefix"] = Array(shots.times.prefix(10))
          let model = VideoPreviewModel()
          await model.load(shots.frame(at: 22))
          result["cropCreated"] = model.image != nil
          result["cropWidth"] = model.image?.width ?? 0; result["cropHeight"] = model.image?.height ?? 0
        } catch { result["imageError"] = error.localizedDescription }
      }
    } catch { result["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) }
  }
  static func featureReadChecks(store: Store, output: URL) async {
    var results: [String: Any] = [:]
    for id in [1005, 1012] {
      do { results["region_\(id)"] = ["count": try await store.api.regionVideos(id, page: 1).count] }
      catch { results["region_\(id)"] = ["error": error.localizedDescription] }
    }
    do {
      let detail = try await store.api.detail("BV1RSnc6nEfN")
      let model = VideoExtras()
      await model.load(detail: detail, cid: detail.pages.first?.id ?? 0, api: store.api)
      results["video"] = ["related": model.related.count, "tags": model.tags.count, "subtitles": model.subtitles.count,
        "chapters": model.chapters.count, "shots": model.shots?.times.count ?? 0, "collection": detail.collection?.items.count ?? 0,
        "error": model.error ?? "", "metadataError": model.subtitleError ?? ""]
      if let subtitle = model.subtitles.first { await model.selectSubtitle(subtitle.id, api: store.api); results["subtitleCues"] = model.lines.count }
    } catch { results["videoError"] = error.localizedDescription }
    do { results["suggestions"] = try await store.api.suggestions("相机").count } catch { results["suggestionError"] = error.localizedDescription }
    do { results["userSearch"] = try await store.api.searchUsers("地上相机AAA", page: 1).count } catch { results["userSearchError"] = error.localizedDescription }
    do {
      let panel = try await store.api.request("/x/emote/user/panel/web", ["business": "reply"])
      results["emojiPackages"] = (panel["packages"] as? [Any])?.count ?? 0
    } catch { results["emojiError"] = error.localizedDescription }
    if store.api.signedIn {
      let blacklist = BlacklistModel(); await blacklist.load(api: store.api)
      let firstCount = blacklist.rows.count
      await blacklist.load(api: store.api)
      results["blacklist"] = ["page1Count": firstCount, "page2Count": blacklist.rows.count, "hasMore": blacklist.hasMore, "error": blacklist.error ?? ""]
      let inbox = InboxModel(); await inbox.load(api: store.api)
      results["conversationPage1"] = inbox.paginationDiagnostics
      await inbox.load(api: store.api, more: true)
      results["conversationPage2"] = inbox.paginationDiagnostics
      if let conversation = inbox.conversations.first(where: { !$0.system }) { inbox.select(conversation); await inbox.loadMessages(api: store.api, markRead: false) }
      results["messages"] = ["count": inbox.messages.count, "emotes": inbox.emotes.count, "error": inbox.messageError ?? ""]
    }
    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: output, options: .atomic) }
  }
  static func special(store: Store, output: URL, bvid: String) async {
    do {
      let detail = try await store.api.detail(bvid)
      guard let cid = detail.pages.first?.id else { return }
      let items = try await DanmakuController.all(cid: cid, duration: min(360,detail.video.duration), api: store.api)
      try JSONEncoder().encode(items).write(to: output, options: .atomic)
    } catch {
      try? Data(error.localizedDescription.utf8).write(to: output.appendingPathExtension("error"))
    }
  }
  static func state(store: Store, output: URL) async {
    // Opt-in diagnostics only: observe actual decoded frames as well as the media clock.
    // Normal launches never create this output or poll pixel buffers.
    let frameOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    var observedItem: AVPlayerItem?
    var lastInput = ProcessInfo.processInfo.systemUptime
    let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged,
    ]) { event in
      lastInput = ProcessInfo.processInfo.systemUptime
      return event
    }
    defer {
      observedItem?.remove(frameOutput)
      if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }
    while !Task.isCancelled {
      if store.playback.player.currentItem !== observedItem {
        observedItem?.remove(frameOutput)
        observedItem = store.playback.player.currentItem
        observedItem?.add(frameOutput)
      }
      let time = store.playback.player.currentTime().seconds
      let itemTime = frameOutput.itemTime(forHostTime: CACurrentMediaTime())
      var frameTime = CMTime.invalid
      let newFrame = frameOutput.hasNewPixelBuffer(forItemTime: itemTime)
      if newFrame { _ = frameOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &frameTime) }
      let state: [String: Any] = [
        "appActive": NSApp.isActive,
        "windowGeometry": [
          "frame": NSApp.mainWindow.map { NSStringFromRect($0.frame) } ?? "",
          "content": NSApp.mainWindow?.contentView.map { NSStringFromRect($0.frame) } ?? "",
          "screen": NSApp.mainWindow?.screen.map { NSStringFromRect($0.frame) } ?? "",
          "fullscreen": store.fullscreen.isPresented,
        ] as [String: Any],
        "inputIdleSeconds": ProcessInfo.processInfo.systemUptime - lastInput,
        "firstResponder": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
        "time": time.isFinite ? time : 0,
        "loading": store.playback.loading,
        "buffering": store.playback.buffering,
        "boosting": store.playback.isBoosting,
        "temporarySpeed": store.playback.temporarySpeed,
        "newDecodedFrame": newFrame,
        "decodedFrameTime": frameTime.seconds.isFinite ? frameTime.seconds : -1,
        "showPlayer": store.showPlayer,
        "miniPlayer": store.showsMiniPlayer,
        "playbackGeneration": store.playback.generation.uuidString,
        "feed": ["count": store.videos.count, "page": store.page, "busy": store.busy,
                 "requestMS": store.feedMilliseconds, "error": store.error ?? ""] as [String: Any],
        "comments": ["loaded": store.comments.items.count, "page": store.comments.page,
                     "hasMore": store.comments.hasMore, "error": store.comments.error ?? ""] as [String: Any],
        "interactionError": store.videoActions.error ?? "",
        "history": [
          "syncing": store.historySync.syncing, "syncError": store.historySync.error ?? "",
          "localCount": store.history.count, "remoteCount": store.accountHistory.items.count,
          "remoteLatest": store.accountHistory.items.prefix(3).map {
            ["bvid": $0.video.bvid, "cid": $0.cid, "progress": $0.progress,
             "viewedAt": $0.viewedAt.timeIntervalSince1970] as [String: Any]
          },
        ] as [String: Any],
        "interaction": store.videoActions.relation.map { ["liked": $0.liked, "coins": $0.coins, "favorite": $0.favorited] as [String: Any] } ?? [:],
        "commentCursor": store.comments.paginationDiagnostics,
        "conversationCursor": store.inbox.paginationDiagnostics,
        "personAvoidance": store.playback.personAvoidance.statistics,
        "loadingStage": store.playback.loadingMessage,
        "cdn": store.playback.routeDiagnostics,
        "cdnProbes": await store.playback.cdnAttempts(),
        "startupMS": store.playback.startupMilliseconds,
        "network": await store.playback.networkStats(),
        "transfer": await store.playback.transferStats(),
        "item": itemState(store.playback),
        "bvid": store.playback.detail?.video.bvid ?? "",
        "size": store.playback.actualSize,
        "renderedFrame": store.playback.renderedFrame,
        "error": store.playback.error ?? "",
        "rate": store.playback.player.rate,
        "waiting": store.playback.player.reasonForWaitingToPlay?.rawValue ?? "",
        "danmakuCount": store.danmaku.items.count,
        "danmakuError": store.danmaku.error ?? "",
        "enabled": store.danmaku.enabled,
        "overlay": store.playback.nativeView?.danmaku.statistics() ?? [:],
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: state, options: [.sortedKeys, .prettyPrinted])
      {
        try? data.write(to: output, options: .atomic)
      }
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
    }
  }
  static func itemState(_ p: Playback) -> [String: Any] {
    guard let item = p.player.currentItem else { return [:] }
    let duration = item.duration.seconds
    return ["status": item.status.rawValue, "duration": duration.isFinite ? duration : -1,
            "time": p.player.currentTime().seconds.isFinite ? p.player.currentTime().seconds : -1,
            "rate": p.player.rate, "waitingReason": p.player.reasonForWaitingToPlay?.rawValue ?? "",
            "canPlayFastForward": item.canPlayFastForward, "volume": p.player.volume, "muted": p.player.isMuted,
            "bufferEmpty": item.isPlaybackBufferEmpty, "likelyToKeepUp": item.isPlaybackLikelyToKeepUp,
            "ranges": item.loadedTimeRanges.map { value in
              let r = value.timeRangeValue
              return [r.start.seconds, r.duration.seconds].map { $0.isFinite ? $0 : -1 }
            },
            "errors": item.errorLog()?.events.suffix(4).map { ["domain": $0.errorDomain, "code": String($0.errorStatusCode)] } ?? []]
  }
  static func nativeFeatures(store: Store, output: URL) async {
    var result: [String: Any] = [:]
    func check(_ name: String, _ operation: () async throws -> Int) async {
      do { result[name] = try await operation() } catch {
        result[name] = error.localizedDescription
      }
    }
    await check("conversations") {
      let data = try await store.api.messageRequest(
        "/session_svr/v1/session_svr/get_sessions",
        ["session_type": "4", "size": "30", "mobi_app": "web"])
      return (data["session_list"] as? [[String: Any]] ?? []).compactMap(Conversation.parse).count
    }
    for type in ["reply", "at", "like"] {
      await check(type) {
        let data = try await store.api.request("/x/msgfeed/" + type, ["platform": "web"])
        let total = data["total"] as? [String: Any] ?? data
        return (total["items"] as? [[String: Any]] ?? []).compactMap(NativeNotice.parse).count
      }
    }
    await check("dynamic") {
      let data = try await store.api.request("/x/polymer/web-dynamic/v1/feed/all", ["type": "all"])
      return (data["items"] as? [[String: Any]] ?? []).compactMap(DynamicEntry.parse).count
    }
    if let account = store.account {
      for type in ["followings", "followers"] {
        await check(type) {
          let data = try await store.api.request(
            "/x/relation/" + type, ["vmid": String(account.mid), "pn": "1", "ps": "30"])
          return (data["list"] as? [[String: Any]] ?? []).count
        }
      }
      await check("collections") {
        let data = try await store.api.request(
          "/x/polymer/web-space/seasons_series_list",
          ["mid": String(account.mid), "page_num": "1", "page_size": "20"])
        let lists = data["items_lists"] as? [String: Any] ?? [:]
        return (lists["seasons_list"] as? [Any] ?? []).count
          + (lists["series_list"] as? [Any] ?? []).count
      }
    }
    if let data = try? JSONSerialization.data(
      withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: output, options: .atomic)
    }
  }

  static func community(store: Store, output: URL) async {
    var result: [String: Any] = [:]
    func check(_ name: String, _ operation: () async throws -> Int) async {
      do { result[name] = try await operation() } catch {
        result[name] = error.localizedDescription
      }
    }
    await check("recommendations") { try await store.api.recommendations(page: 1).count }
    if let account = store.account {
      await check("favorites") { try await store.api.favoriteFolders(account.mid).count }
      await check("watchLater") { try await store.api.later().count }
      await check("profileVideos") { try await store.api.profileVideos(account.mid, page: 1).count }
      await check("following") { try await store.api.followedVideos(page: 1).count }
    }
    do {
      let detail = try await store.api.detail("BV1MbJ665EHy")
      let replies = try await store.api.request(
        "/x/v2/reply", ["type": "1", "oid": "\(detail.aid)", "pn": "1", "ps": "20", "sort": "1"])
      let rows = (replies["replies"] as? [[String: Any]] ?? []).compactMap(Reply.parse)
      result["comments"] = rows.count
      result["IPLocations"] = rows.filter { !$0.location.isEmpty }.count
      if let cid = detail.pages.first?.id {
        let data = try await store.api.binary(
          "/x/v2/dm/web/seg.so", ["type": "1", "oid": "\(cid)", "segment_index": "1"])
        let items = try ProtoReader.decode(data)
        result["danmaku"] = items.count
        result["danmakuModes"] = Dictionary(grouping: items, by: { $0.mode }).mapValues { $0.count }
          .reduce(into: [String: Int]()) { $0["\($1.key)"] = $1.value }
      }
    } catch { result["communityError"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(
      withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: output, options: .atomic)
    }
  }
  static func run(
    store: Store, output: URL, bvids: [String] = ["BV1qM4y1w716", "BV1rp4y1e745", "BV1oq4y1S7T1"]
  ) async {
    var rows: [[String: Any]] = []
    let p = Playback()
    p.player.volume = 0
    p.persistQualityPreference = false
    let launchArgs = ProcessInfo.processInfo.arguments
    p.connectionOverride = launchArgs.firstIndex(of: "--diagnostic-connections").flatMap { i in launchArgs.indices.contains(i + 1) ? Int(launchArgs[i + 1]) : nil }
    let preview = NSWindow(
      contentRect: NSRect(x: 120, y: 120, width: 1000, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    preview.isReleasedWhenClosed = false
    preview.title = "播放验证"
    preview.contentView = NSHostingView(
      rootView: NativePlayer(playback: p, items: [], enabled: false))
    preview.orderFront(nil)
    defer {
      p.stop()
      preview.close()
    }
    for bvid in bvids {
      do {
        let detail = try await store.api.detail(bvid)
        guard let cid = detail.pages.first?.id else { continue }
        let streams = try await store.api.streams(bvid: bvid, cid: cid)
        var row: [String: Any] = [
          "bvid": bvid, "title": detail.video.title,
          "streams": streams.videos.map { v in
            [
              "quality": v.id, "codecs": v.codecs, "width": v.videoAttributes?.width ?? 0,
              "height": v.videoAttributes?.height ?? 0,
            ] as [String: Any]
          },
        ]
        preview.title = "播放验证 · " + bvid
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "--diagnostic-quality").flatMap { i in args.indices.contains(i + 1) ? Int(args[i + 1]) : nil }
        let quality = override ?? streams.videos.map(\.id).max() ?? 80
        if args.contains("--diagnostic-ranges-only"), let source = API.bestVideo(streams.videos, quality: quality) {
          row["ranges"] = await exactRangeProbes(source)
          rows.append(row)
          let data = try JSONSerialization.data(withJSONObject: ["samples": rows], options: [.prettyPrinted, .sortedKeys])
          try data.write(to: output, options: .atomic)
          continue
        }
        p.open(bvid, api: store.api, quality: quality, resume: { _ in 0 })
        for tick in 0..<480 {
          if tick % 4 == 0 {
            let progress: [String: Any] = ["bvid": bvid, "stage": p.loadingMessage,
              "startupMS": p.startupMilliseconds, "network": await p.networkStats(),
              "item": itemState(p), "cdn": await p.cdnAttempts(), "transfer": await p.transferStats()]
            if let data = try? JSONSerialization.data(withJSONObject: progress, options: [.prettyPrinted, .sortedKeys]) {
              try? data.write(to: output.appendingPathExtension("progress.json"), options: .atomic)
            }
          }
          if p.error != nil || (!p.loading && p.player.currentItem?.status == .readyToPlay) {
            break
          }
          try? await Task.sleep(for: .milliseconds(250))
        }
        var timeline: [[String: Any]] = []
        let observation = args.firstIndex(of: "--diagnostic-duration").flatMap { i in args.indices.contains(i + 1) ? Int(args[i + 1]) : nil } ?? 15
        for _ in 0..<max(1, min(120, observation)) {
          timeline.append(["time": p.player.currentTime().seconds.isFinite ? p.player.currentTime().seconds : -1,
                           "loading": p.loading, "buffering": p.buffering,
                           "network": await p.networkStats(), "item": itemState(p)])
          try? await Task.sleep(for: .seconds(1))
        }
        row["timeline"] = timeline
        if args.contains("--diagnostic-quality-cycle") {
          var switches: [[String: Any]] = []
          if args.contains("--diagnostic-4k"), p.durationSeconds > 60 {
            p.seek(to: p.durationSeconds * 0.55)
            try? await Task.sleep(for: .seconds(5))
          }
          for (index, target) in (args.contains("--diagnostic-4k") ? [120, 80, 120] : [64, 80, 64]).enumerated() where streams.videos.contains(where: { $0.id == target }) {
            if index == 1 { p.player.pause() }
            if index == 2 { p.togglePlayback() }
            let before = p.player.currentTime().seconds
            p.selectQuality(target, api: store.api)
            for _ in 0..<240 {
              if p.error != nil || !p.loading { break }
              try? await Task.sleep(for: .milliseconds(250))
            }
            switches.append(["target": target, "before": before.isFinite ? before : -1,
              "startupMS": p.startupMilliseconds, "item": itemState(p),
              "error": p.error ?? "", "loading": p.loading, "frame": p.renderedFrame,
              "network": await p.networkStats(), "cdn": await p.cdnAttempts(),
              "transfer": await p.transferStats()])
            row["switches"] = switches
            if let data = try? JSONSerialization.data(withJSONObject: ["samples": rows + [row]], options: [.prettyPrinted, .sortedKeys]) {
              try? data.write(to: output, options: .atomic)
            }
            try? await Task.sleep(for: .seconds(2))
          }
        }
        if args.contains("--diagnostic-seek"), let duration = p.player.currentItem?.duration.seconds,
          duration.isFinite, duration > 60, p.error == nil {
          let target = duration * 0.55
          p.seekBy(target - p.player.currentTime().seconds)
          try? await Task.sleep(for: .seconds(10))
          row["seek"] = ["target": target, "time": p.player.currentTime().seconds,
                         "rate": p.player.rate, "item": itemState(p)] as [String: Any]
        }
        row["item"] = itemState(p)
        row["expectedDuration"] = detail.pages.first?.duration ?? detail.video.duration
        if let selected = API.bestVideo(streams.videos, quality: quality),
          let info = try? await withDeadline(
            seconds: 10, operation: { try await VideoSignalling.inspect(selected).1 })
        {
          row["sampleType"] = info.sampleType
          row["transfer"] = info.transfer
          row["dolbyProfile"] = info.dolbyProfile
          row["dolbyLevel"] = info.dolbyLevel
          row["compatibility"] = info.compatibility
          row["baseCodec"] = info.baseCodec
        }
        if args.contains("--diagnostic-ranges"), let source = API.bestVideo(streams.videos, quality: quality) {
          var probes: [[String: Any]] = []
          for url in source.urlCandidates.prefix(3) {
            for offset: Int64 in [0, 10_485_760, 31_457_280] {
              let start = ContinuousClock.now
              do {
                let result = try await withDeadline(seconds: 8) {
                  try await HTTPRangeClient().fetch(from: [url], range: HTTPByteRange(start: offset, endInclusive: offset + 1_048_575), headers: API.mediaHeaders)
                }
                let c = start.duration(to: .now).components
                probes.append(["host": url.host ?? "", "offset": offset, "bytes": result.body.count, "ms": Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)])
              } catch { probes.append(["host": url.host ?? "", "offset": offset, "errorType": String(reflecting: type(of: error))]) }
            }
          }
          row["independentRanges"] = probes
        }
        row["videoTransfer"] = await p.transferStats()
        row["cdn"] = p.routeDiagnostics
        row["cdnProbes"] = await p.cdnAttempts()
        row["startupMS"] = p.startupMilliseconds
        row["selected"] = p.selectedQuality
        row["size"] = p.actualSize
        row["sourceFormat"] = p.sourceFormat
        row["decodedFormat"] = p.decodedFormat
        row["time"] = p.player.currentTime().seconds.isFinite ? p.player.currentTime().seconds : -1
        row["error"] = p.error ?? ""
        row["renderedFrame"] = p.renderedFrame
        row["failureCode"] = p.failureCode
        row["ready"] = p.player.currentItem?.status == .readyToPlay
        rows.append(row)
        p.stop()
      } catch { rows.append(["bvid": bvid, "error": error.localizedDescription]) }
      let report: [String: Any] = [
        "loggedIn": store.account != nil, "HDRDisplayEligible": AVPlayer.eligibleForHDRPlayback,
        "samples": rows,
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: output, options: .atomic)
      }
    }

  }

  private static func exactRangeProbes(_ source: MediaRepresentation) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    for url in source.urlCandidates.prefix(3) {
      for (offset, end): (Int64, Int64) in [(29_445_366, 30_493_941), (30_490_091, 30_493_941), (30_493_942, 31_542_517), (31_457_280, 32_505_855)] {
        for mode in ["stream", "urlsession"] {
          let range = try! HTTPByteRange(start: offset, endInclusive: end)
          let bytes = Mutex(0)
          let began = ContinuousClock.now
          var row: [String: Any] = ["host": url.host ?? "", "offset": offset, "end": end, "transport": mode]
          do {
            if mode == "stream" {
              _ = try await withDeadline(seconds: 8) {
                try await HTTPRangeStreamingClient().stream(from: url, rangeHeader: range.headerValue,
                  expectedRange: range, expectedCompleteLength: nil, headers: API.mediaHeaders,
                  allowedContentTypes: nil, requiresContentLength: true, onResponse: { _ in },
                  onChunk: { data in bytes.withLock { $0 += data.count } })
              }
            } else {
              let config = URLSessionConfiguration.ephemeral
              config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 8
              let session = URLSession(configuration: config)
              defer { session.invalidateAndCancel() }
              var request = URLRequest(url: url)
              for (key, value) in API.mediaHeaders { request.setValue(value, forHTTPHeaderField: key) }
              request.setValue(range.headerValue, forHTTPHeaderField: "Range")
              let (data, response) = try await session.data(for: request)
              bytes.withLock { $0 = data.count }
              row["status"] = (response as? HTTPURLResponse)?.statusCode
              row["contentRange"] = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
            }
          } catch {
            if case HTTPRangeResponseError.transport(let kind) = error { row["error"] = kind }
            else { row["error"] = "\(String(reflecting: type(of: error))) \((error as NSError).code)" }
          }
          let c = began.duration(to: .now).components
          row["bytes"] = bytes.withLock { $0 }
          row["ms"] = Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
          rows.append(row)
        }
      }
    }
    return rows
  }
}
