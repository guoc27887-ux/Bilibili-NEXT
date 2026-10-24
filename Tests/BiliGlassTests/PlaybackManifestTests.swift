import BiliModels
import BiliNetworking
import Foundation
import Testing
@testable import BiliGlass

private final class ManifestProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var payload = Data()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
      httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.payload)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct PlaybackManifestTests {
  private func track(_ url: String = "https://upos-sz-mirrorcos.bilivideo.com/video.m4s", audio: Bool = false) -> [String: Any] {
    ["id": audio ? 30280 : 80, "baseUrl": url, "codecs": audio ? "mp4a.40.2" : "avc1.640028",
     "mimeType": audio ? "audio/mp4" : "video/mp4", "bandwidth": 128000,
     "width": 1920, "height": 1080, "frameRate": "30",
     "SegmentBase": ["Initialization": "0-999", "indexRange": "1000-1099"]]
  }
  private func streams(_ video: [[String: Any]], audio: [[String: Any]]? = nil) async throws -> Streams {
    ManifestProtocol.payload = try JSONSerialization.data(withJSONObject: ["code": 0,
      "data": ["dash": ["video": video, "audio": audio ?? [track(audio: true)]]]])
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ManifestProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    return try await API(loadCredentials: false, transport: session).streams(bvid: "BV1nWns6xELb", cid: 1)
  }
  @Test func nonStandardPortPrimaryUsesBackup() async throws {
    var video = track("https://node.mcdn.bilivideo.cn:4483/video.m4s")
    video["backupUrl"] = ["https://upos-sz-mirrorcos.bilivideo.com/video.m4s"]
    let parsed = try await streams([video])
    #expect(parsed.videos.first?.primaryURL.host == "upos-sz-mirrorcos.bilivideo.com")
    #expect(parsed.videos.first?.urlCandidates.count == 1)
  }
  @Test func httpMediaUpgradesToHTTPSAndPreservesSignedQuery() async throws {
    let query = "token=fixture%2Fvalue%2B%3D&order=0,1&empty="
    let parsed = try await streams([track("http://upos-sz-mirrorcos.bilivideo.com/video.m4s?" + query)])
    #expect(parsed.videos.first?.primaryURL.absoluteString == "https://upos-sz-mirrorcos.bilivideo.com/video.m4s?" + query)
  }
  @Test func missingPrimaryStillUsesBackupAndDeduplicates() async throws {
    var video = track(); video.removeValue(forKey: "baseUrl")
    video["backup_url"] = ["//upos-sz-mirrorcos.bilivideo.com/video.m4s", "https://upos-sz-mirrorcos.bilivideo.com/video.m4s"]
    let parsed = try await streams([video])
    #expect(parsed.videos.first?.urlCandidates.count == 1)
  }
  @Test func brokenAlternativeDoesNotPoisonPlayableVideoOrAudio() async throws {
    var broken = track(); broken.removeValue(forKey: "SegmentBase")
    var badAudio = track(audio: true); badAudio["baseUrl"] = "https://invalid.example/audio.m4s"
    let parsed = try await streams([broken, track()], audio: [badAudio, track(audio: true)])
    #expect(parsed.videos.count == 1)
    #expect(parsed.audio.codecs == "mp4a.40.2")
  }
  @Test func segmentBaseAcceptsAllPublishedCasingsAndExtraMetadata() async throws {
    for key in ["SegmentBase", "segment_base", "segmentBase"] {
      var video = track(); video.removeValue(forKey: "SegmentBase")
      video[key] = ["initialization": "0-999", "index_range": "1000-1099", "metadata": 1]
      let parsed = try await streams([video])
      #expect(parsed.videos.first?.segmentBase.index.start == 1000)
    }
  }
  @Test func malformedIndexNeverBecomesAValidRangeByDroppingText() async throws {
    for range in ["0-garbage-99", "-1-99", "99-1", "0-", "0-1-2", "0-9223372036854775807"] {
      var broken = track(); broken["SegmentBase"] = ["Initialization": "0-999", "indexRange": range]
      let parsed = try await streams([broken, track()])
      #expect(parsed.videos.count == 1)
    }
  }
  @Test func unsafeAddressesRemainBlockedAfterNormalization() async throws {
    for address in ["http://localhost/video", "http://127.0.0.1/video", "//[::1]/video",
      "http://upos-sz-mirrorcos.bilivideo.com.evil.example/video", "https://evil.example/video",
      "https://secret@upos-sz-mirrorcos.bilivideo.com/video", "https://upos-sz-mirrorcos.bilivideo.com/video#secret",
      "http://upos-sz-mirrorcos.bilivideo.com:8080/video", "file:///tmp/video.mp4"] {
      #expect(BiliMediaCDNURLPolicy().normalizedURL(address) == nil)
      let parsed = try await streams([track(address), track()])
      #expect(parsed.videos.count == 1)
    }
    #expect(!BiliMediaCDNURLPolicy().allows(URL(string: "http://upos-sz-mirrorcos.bilivideo.com/video")!))
  }
  @Test func standardHTTPPortAndMixedAliasBackupsAreUsable() async throws {
    var video = track("")
    video["base_url"] = "http://upos-sz-mirrorcos.bilivideo.com:80/video.m4s"
    video["backupUrl"] = [String]()
    video["backup_url"] = ["https://upos-hz-mirrorakam.akamaized.net/video.m4s"]
    let parsed = try await streams([video])
    #expect(parsed.videos.first?.primaryURL.scheme == "https")
    #expect(parsed.videos.first?.primaryURL.port == nil)
    #expect(parsed.videos.first?.backupURLs.count == 1)
  }
  @Test func invalidDimensionsSkipOnlyThatAlternative() async throws {
    var broken = track(); broken["width"] = -1
    let parsed = try await streams([broken, track()])
    #expect(parsed.videos.count == 1)
    #expect(parsed.diagnostics["manifest.video.0"]?.contains("attributes") == true)
  }
  @Test func allInvalidSourcesReportManifestFailureWithoutSecrets() async throws {
    let secret = "fixture-private-signature"
    do {
      _ = try await streams([track("https://node.mcdn.bilivideo.cn:4483/\(secret)?token=\(secret)")])
      Issue.record("Expected no usable source")
    } catch let error as StreamManifestError {
      #expect(error.kind == "video")
      let report = error.diagnostics.values.joined(separator: "\n") + error.localizedDescription
      #expect(!report.contains(secret))
      #expect(report.contains("https://node.mcdn.bilivideo.cn:4483"))
      #expect(error.diagnostics["manifest.video.0"]?.contains("address") == true)
    }
  }
  @Test func missingAudioIsNotReportedAsVideoAddressFailure() async throws {
    do {
      _ = try await streams([track()], audio: [])
      Issue.record("Expected missing audio")
    } catch let error as StreamManifestError {
      #expect(error.kind == "audio")
      #expect(error.diagnostics["manifest.video.available"] == "1/1")
    }
  }
}
