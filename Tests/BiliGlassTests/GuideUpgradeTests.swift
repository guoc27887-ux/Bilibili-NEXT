import Foundation
import Testing
@testable import BiliGlass

@Suite @MainActor struct GuideUpgradeTests {
  private func fixture(_ body: (UserDefaults) throws -> Void) throws {
    let name = "BiliGuideTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }
  @Test func freshInstallShowsTutorialOnlyOnceAcrossRebuilds() throws {
    try fixture { defaults in
      let first = GuideHistory(defaults: defaults, version: "1.0.3", revision: "a")
      #expect(first.pending(hasSavedLogin: false) == .tutorial)
      // Looking at pending, or closing a manual replay, never consumes the receipt.
      #expect(first.pending(hasSavedLogin: false) == .tutorial)
      first.didPresent()
      #expect(GuideHistory(defaults: defaults, version: "1.0.3", revision: "a").pending(hasSavedLogin: false) == nil)
    }
  }
  @Test func legacyPreferencesAndKeychainOnlyInstallationsGetUpdates() throws {
    try fixture { defaults in
      defaults.set(24, forKey: "videoThreads")
      defaults.set("custom-background", forKey: "backgroundImage")
      let history = GuideHistory(defaults: defaults, version: "1.0.3", revision: "a")
      #expect(history.pending(hasSavedLogin: false) == .update(previous: nil))
      history.didPresent()
      #expect(defaults.integer(forKey: "videoThreads") == 24)
      #expect(defaults.string(forKey: "backgroundImage") == "custom-background")
    }
    try fixture { defaults in
      #expect(GuideHistory(defaults: defaults).pending(hasSavedLogin: true) == .update(previous: nil))
    }
  }
  @Test func versionAndContentRevisionEachPresentOnceAndRollbackDoesNotRepeat() throws {
    try fixture { defaults in
      let old = GuideHistory(defaults: defaults, version: "1.0.2", revision: "a")
      old.didPresent()
      let upgrade = GuideHistory(defaults: defaults, version: "1.2.0", revision: "a")
      #expect(upgrade.pending(hasSavedLogin: true) == .update(previous: "1.0.2"))
      upgrade.didPresent()
      #expect(GuideHistory(defaults: defaults, version: "1.0.2", revision: "a").pending(hasSavedLogin: true) == nil)
      let revised = GuideHistory(defaults: defaults, version: "1.2.0", revision: "b")
      #expect(revised.pending(hasSavedLogin: true) == .update(previous: "1.2.0"))
      revised.didPresent()
      #expect(revised.pending(hasSavedLogin: true) == nil)
    }
  }
  @Test func oldLoginIsPromptedButValidUnifiedOrSeparateAuthorizationIsNot() {
    let now = Date(timeIntervalSince1970: 1000)
    let cookies = ["SESSDATA": "fixture", "DedeUserID": "42"]
    let valid = AppCoinAuthorization(accountID: 42, accessToken: "fixture", expires: now.addingTimeInterval(3600))
    #expect(LoginUpgradeReason.evaluate(cookies: [:], authorization: nil, now: now) == nil)
    #expect(LoginUpgradeReason.evaluate(cookies: cookies, authorization: nil, now: now) == .missingAuthorization)
    #expect(LoginUpgradeReason.evaluate(cookies: cookies, authorization: valid, now: now) == nil)
    #expect(LoginUpgradeReason.evaluate(cookies: ["SESSDATA": "fixture", "DedeUserID": "43"], authorization: valid, now: now) == .expiredAuthorization)
    #expect(LoginUpgradeReason.evaluate(cookies: cookies, authorization: valid, now: now.addingTimeInterval(3600)) == .expiredAuthorization)
    #expect(cookies["SESSDATA"] == "fixture") // The migration decision never mutates credentials.
  }
  @Test func guideIncludesMajorFeaturesAndUpgradeFallbackNeverHasEmptyPages() {
    let ids = Set(GuideContent.tutorial.map(\.id))
    #expect(Set(["account", "browse", "player", "keys", "queue", "actions", "comments", "danmaku", "library", "messages", "network", "downloads", "appearance"]).isSubset(of: ids))
    #expect(ids.count == GuideContent.tutorial.count)
    #expect(!GuideContent.updates(after: "1.0.2").isEmpty)
    #expect(GuideContent.updates(after: nil).contains { $0.id == "release-1.0.2" })
    #expect(GuideContent.updates(after: "1.0.1").contains { $0.id == "release-1.0.2" })
  }
}
