import Foundation
import Testing
@testable import BiliGlass

@Test func bufferRecoveryRequiresContiguousPlayableMedia() {
  #expect(Playback.bufferedAhead(time: 12, ranges: [(0, 15)]) == 3)
  #expect(Playback.bufferedAhead(time: 12, ranges: [(0, 10), (20, 5)]) == 0)
  #expect(Playback.bufferedAhead(time: 0, ranges: [(0, 0), (0, .nan)]) == 0)
  #expect(abs(Playback.bufferedAhead(time: 2.994, ranges: [(3.072, 2.144)]) - 2.222) < 0.001)
  #expect(Playback.bufferedAhead(time: 3, ranges: [(3.4, 5)]) == 0)
  #expect(Playback.bufferedAhead(time: .nan, ranges: [(0, 15)]) == 0)
}

struct InteractionStateTests {
  @Test func publicationDateUsesPublicTimestampAndOldCachesStillDecode() throws {
    let video = try #require(Video.parse(["bvid": "BV1xx411c7mD", "pubdate": 1_700_000_000]))
    #expect(video.publishedAt == Date(timeIntervalSince1970: 1_700_000_000))
    let old = Data(#"{"bvid":"BV1xx411c7mD","title":"old","cover":"","author":"","duration":10,"views":0}"#.utf8)
    #expect(try JSONDecoder().decode(Video.self, from: old).publishedAt == nil)
  }

  @Test func coinOptionsExplainServerLimitExistingCoinsAndBalance() {
    #expect(CoinAvailability(limit: 2, coins: 0, balance: 100.5).available == 2)
    #expect(CoinAvailability(limit: 2, coins: 0, balance: 100.5).reason(for: 2) == nil)
    #expect(CoinAvailability(limit: 1, coins: 0, balance: 100.5).reason(for: 2)?.contains("转载") == true)
    #expect(CoinAvailability(limit: 2, coins: 1, balance: 100.5).reason(for: 2)?.contains("本次最多投 1 枚") == true)
    #expect(CoinAvailability(limit: 2, coins: 0, balance: 1.8).available == 1)
    #expect(CoinAvailability(limit: 2, coins: 0, balance: 1.8).reason(for: 2)?.contains("余额不足") == true)
    #expect(CoinAvailability(limit: 2, coins: nil, balance: 100.5).available == 0)
    #expect(CoinAvailability(limit: 2, coins: 2, balance: 100.5).reason(for: 1) == "本视频已投满")
    #expect(CoinAvailability(limit: 2, coins: 0, balance: .nan).available == 0)
  }
  @Test @MainActor func downloadBadgeFollowsJobStateWithoutRemovingSavedFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let downloads = Downloads(storageDirectory: dir)
    let video = Video(bvid: "fixture", title: "fixture", cover: "", author: "", duration: 10, views: 0)
    let job = DownloadJob(video: video, cid: 1, qn: 80, folder: dir)
    downloads.jobs = [job]
    #expect(downloads.activeCount == 1)
    job.cancel(); #expect(downloads.activeCount == 0)
    job.cancelled = false; #expect(downloads.activeCount == 1)
    job.error = "failed"; #expect(downloads.activeCount == 0)
    job.error = nil; job.finished = true
    #expect(downloads.activeCount == 0)
    #expect(downloads.jobs.count == 1)
  }
  @Test func unsupportedFastForwardNeverAdvertisesThreeTimes() {
    #expect(Playback.temporaryRate(canPlayFastForward: false) == 2)
    #expect(Playback.temporaryRate(canPlayFastForward: true) == 3)
  }
}
