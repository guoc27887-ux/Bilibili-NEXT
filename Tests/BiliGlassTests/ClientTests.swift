import AVFoundation
import Foundation
import Testing

@testable import BiliGlass

@Suite(.serialized)
struct ClientTests {
  @Test func namesAndIDs() {
    #expect(videoID("https://www.bilibili.com/video/BV1xx411c7mD/?p=2") == "BV1xx411c7mD")
    #expect(videoID("hello") == nil)
    #expect(!safeFilename("a/b:c\nd").contains("/"))
    #expect(cleanTitle("<em class=\"keyword\">你好</em>&amp;世界") == "你好&世界")
  }
  @Test @MainActor func wbiReference() {
    let key = API.mixin("7cd084941338484aae1ad9425b84077c4932caff0ff746eab6f01bf08b70ac45")
    #expect(key == "ea1db124af3c7062474693fa704f4ff8")
    let signed = API.sign(
      ["foo": "114", "bar": "514", "baz": "1919810"], key: key, timestamp: 1_702_204_169)
    #expect(signed["w_rid"] == "6149fdadf571698ca7e6a567265cd0ee")
  }
  @Test @MainActor func stopInvalidatesPendingPlayback() {
    let p = Playback()
    let first = p.generation
    p.stop()
    #expect(first != p.generation)
    #expect(p.player.currentItem == nil)
    #expect(!p.loading)
  }
  @Test @MainActor func nativeCompositionRetainsVideoAndAudio() async throws {
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Vendor/BiliKitCore/Tests/BiliPlaybackTests/Fixtures")
    let asset = try await NativeComposition.make(
      video: base.appendingPathComponent("video-avc.mp4"),
      audio: base.appendingPathComponent("audio-aac.mp4"))
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
  }
  @Test @MainActor func muxProducesBothTracks() async throws {
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Vendor/BiliKitCore/Tests/BiliPlaybackTests/Fixtures")
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
      "biliglass-mux-test-\(UUID()).mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    try await Downloads.mux(
      video: base.appendingPathComponent("video-avc.mp4"),
      audio: base.appendingPathComponent("audio-aac.mp4"), output: output)
    #expect(FileManager.default.fileExists(atPath: output.path))
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIGLASS_LIVE_TEST"] == "1")) @MainActor
  func livePlayback() async throws {
    let api = API(loadCredentials: false)
    let feed = try await api.popular(page: 1)
    print("LIVE popular OK")
    #expect(!feed.isEmpty)
    let bvid = ProcessInfo.processInfo.environment["BILIGLASS_BVID"] ?? feed.first!.bvid
    let detail = try await api.detail(bvid)
    print("LIVE detail OK")
    let cid = try #require(detail.pages.first?.id)
    let streams = try await api.streams(bvid: bvid, cid: cid)
    print("LIVE video=\(bvid) qualities=\(streams.videos.map(\.id))")
    let playback = Playback()
    playback.persistQualityPreference = false
    playback.open(bvid, api: api, quality: streams.videos.map(\.id).max(), resume: { _ in 0 })
    defer { playback.stop() }
    for _ in 0..<80 {
      if playback.error != nil
        || (!playback.loading && playback.player.currentItem?.status == .readyToPlay)
      {
        break
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    #expect(playback.error == nil)
    #expect(playback.player.currentItem?.status == .readyToPlay)
    try await Task.sleep(for: .seconds(3))
    #expect(playback.player.currentTime().seconds > 0)
    print("LIVE actual=\(playback.actualSize) time=\(playback.player.currentTime().seconds)")
    if let qn = streams.videos.last?.id, qn != playback.selectedQuality {
      let before = playback.player.currentTime().seconds
      playback.selectQuality(qn, api: api)
      for _ in 0..<60 {
        if playback.error != nil || !playback.loading { break }
        try await Task.sleep(for: .milliseconds(500))
      }
      #expect(playback.error == nil)
      #expect(playback.selectedQuality == qn)
      #expect(playback.player.currentTime().seconds >= before - 1)
      print("LIVE switched=\(playback.selectedQuality) actual=\(playback.actualSize)")
    }
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIGLASS_LIVE_TEST"] == "1")) @MainActor
  func liveSearchAndQR() async throws {
    let api = API(loadCredentials: false)
    let videos = try await api.search("苹果", page: 1)
    #expect(!videos.isEmpty)
    let qr = try await api.request("/x/passport-login/web/qrcode/generate")
    #expect((qr["url"] as? String)?.hasPrefix("https://") == true)
    #expect(qr["qrcode_key"] as? String != nil)
    print("LIVE search results=\(videos.count); QR generation OK")
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIGLASS_DOWNLOAD_TEST"] == "1"))
  @MainActor func liveDownloadAndOfflinePlayback() async throws {
    let api = API(loadCredentials: false)
    let d = try await api.detail("BV1MHJB63Emv")
    let cid = try #require(d.pages.first?.id)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BiliGlass-download-test-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let downloads = Downloads(storageDirectory: folder)
    let job = DownloadJob(video: d.video, cid: cid, qn: 16, folder: folder)
    downloads.jobs = [job]
    await downloads.run(job, api: api)
    #expect(job.error == nil)
    #expect(job.finished)
    let saved = try #require(downloads.saved.first)
    let reloaded = Downloads(storageDirectory: folder)
    #expect(reloaded.saved.first?.path == saved.path)
    let p = Playback()
    p.openLocal(URL(fileURLWithPath: saved.path), video: d.video)
    defer { p.stop() }
    for _ in 0..<40 {
      if !p.loading || p.error != nil { break }
      try await Task.sleep(for: .milliseconds(250))
    }
    #expect(p.error == nil)
    #expect(p.player.currentItem?.status == .readyToPlay)
    try await Task.sleep(for: .seconds(2))
    #expect(p.player.currentTime().seconds > 0)
    print(
      "LIVE download complete; offline actual=\(p.actualSize); playback time=\(p.player.currentTime().seconds)"
    )
  }

}
