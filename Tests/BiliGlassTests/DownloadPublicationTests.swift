import AVKit
import Foundation
import Testing
@testable import BiliGlass

@Suite(.serialized) struct DownloadPublicationTests {
  @Test func relocatingAnIOSContainerKeepsCachedMediaSidecarsAndPausedTasks() {
    let video = Video(bvid: "fixture", title: "test", cover: "", author: "", duration: 10, views: 0)
    let cached = SavedDownload(id: UUID(), video: video, cid: 1, quality: "1080P",
      path: "/old/MediaCache/video.mp4", date: .now, cached: true,
      danmakuPath: "/old/MediaCache/video.danmaku.json")
    let exported = SavedDownload(id: UUID(), video: video, cid: 2, quality: "1080P",
      path: "/exports/video.mp4", date: .now, cached: false)
    let job = PendingDownload(id: UUID(), video: video, cid: 1, qn: 80,
      folder: "/old/MediaCache", cached: true, progress: 0.5)
    let moved = DownloadIndex(saved: [cached, exported], jobs: [job])
      .relocatingCache(to: URL(fileURLWithPath: "/new/MediaCache"))
    #expect(moved.saved[0].path == "/new/MediaCache/video.mp4")
    #expect(moved.saved[0].danmakuPath == "/new/MediaCache/video.danmaku.json")
    #expect(moved.saved[0].id == cached.id)
    #expect(moved.saved[1].path == exported.path)
    #expect(moved.jobs[0].folder == "/new/MediaCache")
    #expect(moved.jobs[0].id == job.id && moved.jobs[0].progress == 0.5)
  }
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func box(_ kind: String, _ payload: Data) -> Data {
    let count = UInt32(payload.count + 8)
    return Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + Data(kind.utf8) + payload
  }
  private func movie(date: UInt8, payload: UInt8, version: UInt8) -> Data {
    let header = Data([version,0,0,0]) + Data(repeating: date, count: version == 1 ? 16 : 8) + Data([0,0,0,42])
    return box("ftyp", Data("fixture".utf8)) + box("moov", box("mvhd", header) + box("trak", box("tkhd", header) + box("mdia", box("mdhd", header)))) + box("mdat", Data(repeating: payload, count: 256))
  }
  @Test(arguments: [UInt8(0), UInt8(1)]) func remuxDatesAreIgnoredButMediaChangesAreNot(version: UInt8) throws {
    let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a.mp4"), b = root.appendingPathComponent("b.mp4")
    try movie(date: 1, payload: 8, version: version).write(to: a)
    try movie(date: 2, payload: 8, version: version).write(to: b)
    #expect(try DownloadPublication.digest(a) == DownloadPublication.digest(b))
    try movie(date: 2, payload: 9, version: version).write(to: b)
    #expect(try DownloadPublication.digest(a) != DownloadPublication.digest(b))
  }
  @Test func publicationIsIdempotentAndKeepsDifferentExistingFiles() throws {
    let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("complete.mp4"), target = root.appendingPathComponent("video.mp4")
    try movie(date: 1, payload: 8, version: 0).write(to: output)
    let prepared = try DownloadPublication.prepare(output, quality: "1080P")
    let original = Data("existing user file".utf8); try original.write(to: target)
    let alternate = try DownloadPublication.publish(output, to: target, prepared: prepared)
    #expect(alternate.lastPathComponent == "video (2).mp4")
    #expect(try Data(contentsOf: target) == original)
    #expect(try DownloadPublication.publish(output, to: target, prepared: prepared) == alternate)
    #expect(try DownloadPublication.restore(output)?.digest == prepared.digest)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".partial") })
    try movie(date: 1, payload: 9, version: 0).write(to: output)
    #expect(try DownloadPublication.restore(output) == nil)
  }
  @Test @MainActor func completedCheckpointCommitsOnceAndRemovesTransferDirectory() async throws {
    let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults.standard, previous = defaults.object(forKey: "downloadDanmaku")
    defaults.set(false, forKey: "downloadDanmaku"); defer { defaults.set(previous, forKey: "downloadDanmaku") }
    let downloads = Downloads(storageDirectory: root)
    let video = Video(bvid: "BV1xx411c7mD", title: "fixture", cover: "", author: "", duration: 10, views: 0)
    let job = DownloadJob(video: video, cid: 12, qn: 80, folder: root.appendingPathComponent("MediaCache"), cached: true)
    let temp = root.appendingPathComponent("Transfers/\(job.id)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let output = temp.appendingPathComponent("complete.mp4")
    try movie(date: 1, payload: 8, version: 0).write(to: output)
    _ = try DownloadPublication.prepare(output, quality: "1080P")
    downloads.jobs.append(job)
    let api = API(loadCredentials: false)
    await downloads.run(job, api: api)
    #expect(job.finished); #expect(job.error == nil); #expect(downloads.saved.count == 1)
    #expect(!FileManager.default.fileExists(atPath: temp.path))
    let restored = Downloads(storageDirectory: root)
    #expect(restored.jobs.isEmpty); #expect(restored.saved.first?.id == job.id)
    await downloads.run(job, api: api)
    #expect(downloads.saved.count == 1)
  }
  @Test @MainActor func inactiveKeyboardCannotCancelAnotherViewsTemporarySpeed() {
    let playback = Playback(), view = NativeVideoView()
    let keyboard = PlayerKeyboard(view: view, playback: playback)
    playback.isBoosting = true
    keyboard.cancelHeldKey(); keyboard.stop()
    #expect(playback.isBoosting)
    playback.endTemporarySpeed()
  }
}
