import AVFoundation
import AppKit
import BiliModels
import BiliNetworking
import Foundation
import SwiftUI
import Synchronization

@MainActor enum Diagnostics {
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
        "feed": ["count": store.videos.count, "page": store.page, "busy": store.busy,
                 "requestMS": store.feedMilliseconds, "error": store.error ?? ""] as [String: Any],
        "comments": ["loaded": store.comments.items.count, "page": store.comments.page,
                     "hasMore": store.comments.hasMore, "error": store.comments.error ?? ""] as [String: Any],
        "interactionError": store.videoActions.error ?? "",
        "commentCursor": store.comments.paginationDiagnostics,
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
