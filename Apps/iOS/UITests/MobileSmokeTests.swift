import XCTest

@MainActor final class MobileSmokeTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func interactionApp(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-navigation", "--qa-app-coins"] + extra
    app.launch()
    XCTAssertTrue(app.buttons["video-coin"].waitForExistence(timeout: 15))
    return app
  }

  func testClientCoinFlowUpdatesLimitsWithoutVerificationButtons() {
    let app = interactionApp()
    app.buttons["video-coin"].tap()
    let submit = app.buttons["submit-coins"]
    XCTAssertTrue(submit.waitForExistence(timeout: 8))
    XCTAssertTrue(submit.isEnabled)
    XCTAssertFalse(app.buttons["官方验证"].exists)
    XCTAssertFalse(app.buttons["重新登录"].exists)
    submit.tap()
    XCTAssertTrue(app.staticTexts["已投 1 枚硬币"].waitForExistence(timeout: 8))
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["coin-amount-2"].isEnabled)
    XCTAssertTrue(app.staticTexts["已投 1 枚，本次最多投 1 枚"].waitForExistence(timeout: 5))
    attach("client-coin-confirmed", app: app)
    app.buttons["submit-coins"].tap()
    XCTAssertTrue(app.buttons["video-coin"].waitForExistence(timeout: 8))
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.staticTexts["本视频已投满"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["submit-coins"].isEnabled)
  }

  func testExpiredClientLoginOpensUnifiedQRAndCancelPreservesAccount() {
    let app = interactionApp(["--qa-token-expired"])
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    app.buttons["submit-coins"].tap()
    XCTAssertTrue(app.staticTexts["请重新登录后再试"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["官方验证"].exists)
    for _ in 0..<4 {
      if app.buttons["interaction-relogin"].isHittable { break }
      app.collectionViews.firstMatch.swipeUp()
    }
    app.buttons["interaction-relogin"].tap()
    XCTAssertTrue(app.buttons["保存二维码到相册"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["使用哔哩哔哩 App 扫码，并确认登录"].waitForExistence(timeout: 8))
    attach("client-login-qr", app: app)
    app.buttons["关闭"].tap()
    XCTAssertTrue(app.buttons["video-coin"].waitForExistence(timeout: 8))
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.staticTexts["登录哔哩哔哩"].exists)
  }

  func testQRLoginRecoversNetworkLossAndBackgroundWithoutReplacingCode() {
    let app = interactionApp(["--qa-token-expired", "--qa-login-network-loss"])
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    app.buttons["submit-coins"].tap()
    for _ in 0..<4 {
      if app.buttons["interaction-relogin"].isHittable { break }
      app.collectionViews.firstMatch.swipeUp()
    }
    app.buttons["interaction-relogin"].tap()
    XCTAssertTrue(app.staticTexts["连接暂时中断，正在恢复登录确认…"].waitForExistence(timeout: 8))
    let waiting = app.staticTexts["使用哔哩哔哩 App 扫码，并确认登录"]
    XCTAssertTrue(waiting.waitForExistence(timeout: 8))
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(waiting.waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["保存二维码到相册"].isEnabled)
    XCTAssertFalse(app.buttons["刷新二维码"].exists)
    attach("qr-login-resumed", app: app)
    app.buttons["关闭"].tap()
  }

  func testTripleHoldCancelsOnReleaseAndCompletesWithoutExtraLike() {
    let app = interactionApp()
    let like = app.buttons["video-like"]
    XCTAssertTrue(like.waitForExistence(timeout: 8))
    like.tap()
    if !app.staticTexts["已点赞"].waitForExistence(timeout: 5) { print(app.debugDescription) }
    XCTAssertTrue(app.staticTexts["已点赞"].exists)
    XCTAssertEqual(like.value as? String, "1")
    like.tap()
    XCTAssertTrue(app.staticTexts["已取消点赞"].waitForExistence(timeout: 5))
    XCTAssertEqual(like.value as? String, "0")
    like.press(forDuration: 0.6)
    XCTAssertTrue(app.staticTexts["已取消点赞"].exists)
    XCTAssertFalse(app.staticTexts["triple-progress"].exists)
    XCTAssertEqual(like.value as? String, "0")
    like.press(forDuration: 1.5)
    XCTAssertTrue(app.staticTexts["已三连"].waitForExistence(timeout: 8))
    XCTAssertEqual(app.buttons["video-like"].value as? String, "1")
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.staticTexts["本视频已投满"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["submit-coins"].isEnabled)
    attach("triple-hold-confirmed", app: app)
  }

  func testCoinTimeoutRequiresRefreshBeforeAnotherSubmission() {
    let app = interactionApp(["--qa-coin-timeout"])
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    app.buttons["submit-coins"].tap()
    XCTAssertTrue(app.staticTexts["投币结果未确认，请刷新状态后再操作"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["submit-coins"].isEnabled)
    XCTAssertTrue(app.buttons["刷新状态"].isEnabled)
    XCTAssertTrue(app.buttons["重新登录"].exists)
    XCTAssertFalse(app.buttons["官方验证"].exists)
    attach("coin-uncertain-state", app: app)
  }

  func testNavigationSearchAndLocalHistory() throws {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["首页"].waitForExistence(timeout: 15))
    app.buttons["资料库"].tap()
    XCTAssertTrue(app.navigationBars["资料库"].exists)
    app.buttons["观看记录"].tap()
    XCTAssertTrue(app.navigationBars["观看记录"].waitForExistence(timeout: 5))
    attach("history", app: app)
    app.buttons["我的"].tap()
    for _ in 0..<6 {
      if app.buttons["设置"].isHittable { break }
      app.swipeUp()
    }
    app.buttons["设置"].tap()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    attach("settings", app: app)
    app.buttons["首页"].tap()
    app.buttons["搜索"].tap()
    attach("search-before-input", app: app)
    if !app.searchFields.firstMatch.waitForExistence(timeout: 5) { print(app.debugDescription) }
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    app.searchFields.firstMatch.tap()
    app.searchFields.firstMatch.typeText("SwiftUI\n")
    attach("search", app: app)
  }

  func testLivePlaybackAndMiniPlayer() throws {
    guard ProcessInfo.processInfo.environment["BILI_IOS_LIVE_TEST"] == "1" else {
      throw XCTSkip("Set BILI_IOS_LIVE_TEST=1 to enable read-only live media validation")
    }
    let app = XCUIApplication()
    app.launchArguments = [
      "--qa-video", ProcessInfo.processInfo.environment["BILI_IOS_BVID"] ?? "BV1AHnB6NEhM",
    ]
    app.launch()
    XCTAssertTrue(app.navigationBars["正在播放"].waitForExistence(timeout: 20))
    app.buttons["播放详情"].tap()
    XCTAssertTrue(app.navigationBars["播放详情"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      waitForValue("rendered-frame-status", "是", app: app, timeout: 60),
      "AVKit must report a rendered video frame"
    )
    attach("live-playback-details", app: app)
    app.buttons["完成"].tap()
    checkMiniPlayer(app)
  }

  func testMiniPlayerAcrossTabs() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-video", "BV1AHnB6NEhM"]
    app.launch()
    XCTAssertTrue(app.navigationBars["正在播放"].waitForExistence(timeout: 20))
    checkMiniPlayer(app)
  }

  func testLongPressWithLocalFixture() throws {
    guard let fixture = ProcessInfo.processInfo.environment["BILI_IOS_FIXTURE"] else {
      throw XCTSkip(
        "Copy a local MP4 into app Documents/QA and set BILI_IOS_FIXTURE to its filename")
    }
    let app = XCUIApplication()
    app.launchArguments = ["--qa-fixture", fixture]
    app.launch()
    XCTAssertTrue(app.navigationBars["正在播放"].waitForExistence(timeout: 20))
    app.buttons["播放详情"].tap()
    XCTAssertTrue(waitForValue("rendered-frame-status", "是", app: app))
    app.buttons["完成"].tap()
    let video = app.otherElements["video-player"].firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 5))
    video.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)).press(forDuration: 2)
    app.buttons["播放详情"].tap()
    XCTAssertTrue(waitForValue("temporary-speed-status", "未启用", app: app))
    attach("long-press-released", app: app)
  }
  func testSpecialDanmakuWithLocalFixture() throws {
    guard let fixture = ProcessInfo.processInfo.environment["BILI_IOS_FIXTURE"] else {
      throw XCTSkip("Requires local MP4 and special.json fixtures in app Documents/QA")
    }
    let app = XCUIApplication()
    app.launchArguments = ["--qa-fixture", fixture, "--qa-special"]
    app.launch()
    XCTAssertTrue(app.navigationBars["正在播放"].waitForExistence(timeout: 20))
    attach("advanced-danmaku", app: app)
    app.buttons["播放详情"].tap()
    let count = app.descendants(matching: .any)["special-layer-count"].firstMatch
    XCTAssertTrue(count.waitForExistence(timeout: 10))
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != '0'"), object: count)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 20), .completed)
    attach("advanced-danmaku-details", app: app)
  }

  func testDoneSavesFavoriteSelectionWithManyFolders() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-favorite-form"]
    app.launch()
    let folder = app.switches["favorite-folder-1"]
    XCTAssertTrue(folder.waitForExistence(timeout: 15))
    XCTAssertEqual(folder.value as? String, "0")
    XCTAssertTrue(folder.label.contains("私密"))
    XCTAssertTrue(app.switches["favorite-folder-2"].label.contains("公开"))
    // The row and its native UISwitch are separate accessibility elements.
    folder.switches.firstMatch.tap()
    XCTAssertEqual(folder.value as? String, "1")
    app.buttons["save-favorites"].tap()
    let closed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.buttons["save-favorites"])
    XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "收藏，")).firstMatch.tap()
    XCTAssertTrue(folder.waitForExistence(timeout: 5))
    XCTAssertEqual(folder.value as? String, "1")
    attach("favorite-saved-and-reopened", app: app)
    app.buttons["取消"].tap()
  }
  func testInboxLayoutCategoriesAndUnreadFilter() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui"]
    app.launch()
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["conversation-1:11"].waitForExistence(timeout: 10))
    attach("inbox-light", app: app)
    app.buttons["inbox-filter-unread"].tap()
    XCTAssertFalse(app.buttons["conversation-1:12"].exists)
    XCTAssertTrue(app.buttons["conversation-1:11"].exists)
    app.buttons["inbox-filter-all"].tap()
    XCTAssertTrue(app.buttons["conversation-1:12"].exists)
    for kind in 1...3 {
      app.buttons["inbox-category-\(kind)"].tap()
      if !app.staticTexts["这里显示被回复的原文。"].waitForExistence(timeout: 5) {
        print(app.debugDescription)
      }
      XCTAssertTrue(app.staticTexts["这里显示被回复的原文。"].exists)
      attach("inbox-category-\(kind)", app: app)
      goBack(app)
    }
    app.buttons["inbox-system"].tap()
    XCTAssertTrue(app.staticTexts["系统通知 1"].waitForExistence(timeout: 5))
    attach("system-notifications", app: app)
    goBack(app)
    XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
    app.buttons["conversation-1:12"].tap()
    XCTAssertTrue(app.staticTexts["本地会话内容"].waitForExistence(timeout: 5))
    attach("conversation", app: app)
    app.buttons["查看消息图片"].tap()
    let zoom = app.scrollViews["image-zoom-view"]
    XCTAssertTrue(zoom.waitForExistence(timeout: 5))
    zoom.doubleTap()
    XCTAssertTrue(waitForValue("image-zoom-view", "已放大", app: app))
    zoom.swipeLeft()
    attach("gallery-zoom-and-pan", app: app)
    zoom.doubleTap()
    XCTAssertTrue(waitForValue("image-zoom-view", "适应屏幕", app: app))
    app.buttons["完成"].tap()
  }

  func testInboxFailureRetryAndEmptyStates() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-ui-error", "--qa-ui-empty"]
    app.launch()
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 10))
    attach("inbox-offline", app: app)
    app.buttons["重试"].tap()
    XCTAssertTrue(app.staticTexts["暂无私信"].waitForExistence(timeout: 5))
    app.buttons["inbox-filter-unread"].tap()
    XCTAssertTrue(app.staticTexts["没有未读消息"].exists)
    app.buttons["动态"].tap()
    XCTAssertTrue(app.staticTexts["暂无动态"].waitForExistence(timeout: 5))
    app.buttons["资料库"].tap()
    app.buttons["收藏"].tap()
    XCTAssertTrue(app.staticTexts["还没有收藏夹"].waitForExistence(timeout: 5))
    attach("favorite-empty", app: app)
  }

  func testInboxLargeTextAndSettingsNavigation() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--qa-ui", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL", "-appearance", "dark",
    ]
    app.launch()
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["inbox-category-1"].waitForExistence(timeout: 10))
    attach("inbox-dark-large-text", app: app)
    app.buttons["我的"].tap()
    for _ in 0..<6 {
      if app.buttons["设置"].isHittable { break }
      app.swipeUp()
    }
    app.buttons["设置"].tap()
    for _ in 0..<8 {
      if app.buttons["过滤与滚动设置"].isHittable { break }
      app.swipeUp()
    }
    app.buttons["过滤与滚动设置"].tap()
    XCTAssertTrue(app.navigationBars["弹幕设置"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.navigationBars.count, 1)
    attach("danmaku-settings-large-text", app: app)
    goBack(app)
    XCTAssertTrue(app.navigationBars["设置"].exists)
  }

  func testUserSearchClearsStaleResultsAfterFailure() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui"]
    app.launch()
    app.buttons["首页"].tap()
    app.buttons["搜索"].tap()
    app.buttons["搜索筛选"].tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "搜索类型")).firstMatch.tap()
    app.buttons["用户"].tap()
    app.buttons["完成"].tap()
    let field = app.searchFields.firstMatch
    field.tap()
    field.typeText("甲\n")
    XCTAssertTrue(app.staticTexts["搜索用户 甲"].waitForExistence(timeout: 5))
    field.tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "失败\n")
    XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["搜索用户 甲"].exists)
    attach("search-error-without-stale-results", app: app)
  }

  func testPlayerReturnsThroughProfileAndPreservesComments() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-navigation"]
    app.launch()
    XCTAssertTrue(app.staticTexts["player-title"].waitForExistence(timeout: 10))
    let comments = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "评论 "))
      .firstMatch
    for _ in 0..<5 {
      if comments.isHittable { break }
      app.swipeUp()
    }
    comments.tap()
    let draft = app.descendants(matching: .any).matching(identifier: "comment-draft").firstMatch
    for _ in 0..<5 {
      if draft.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(draft.waitForExistence(timeout: 5))
    draft.tap()
    if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
    draft.typeText("保留的评论草稿")
    app.swipeDown()
    let author = app.buttons["player-author"].firstMatch
    for _ in 0..<5 {
      if author.isHittable { break }
      app.swipeDown()
    }
    author.tap()
    XCTAssertTrue(app.navigationBars["导航测试 UP 主"].waitForExistence(timeout: 5))
    attach("navigation-profile", app: app)
    let next = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导航测试视频 B")).firstMatch
    for _ in 0..<5 {
      if next.isHittable { break }
      app.swipeUp()
    }
    next.tap()
    XCTAssertTrue(app.staticTexts["player-title"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["player-title"].label, "导航测试视频 B")
    attach("navigation-video-b", app: app)
    goBack(app)
    XCTAssertTrue(app.navigationBars["导航测试 UP 主"].waitForExistence(timeout: 5))
    goBack(app)
    for _ in 0..<5 {
      if draft.exists { break }
      app.swipeUp()
    }
    XCTAssertEqual(draft.value as? String, "保留的评论草稿")
    attach("navigation-restored-comments", app: app)
    app.buttons["播放详情"].tap()
    XCTAssertTrue(app.navigationBars["播放详情"].waitForExistence(timeout: 5))
    attach("navigation-restored-details", app: app)
    app.buttons["完成"].tap()
    app.buttons["收起播放器"].tap()
    XCTAssertTrue(app.buttons["关闭播放器"].waitForExistence(timeout: 5))
  }

  func testLibraryAndAccountPages() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-ui-pages", "-appearance", "light"]
    app.launch()
    attach("home", app: app)
    for name in ["热门", "分区", "推荐"] {
      app.buttons[name].tap()
      attach("home-" + name, app: app)
    }
    app.buttons["动态"].tap()
    attach("dynamics", app: app)
    app.buttons["发布动态"].tap()
    XCTAssertTrue(app.navigationBars["发布动态"].waitForExistence(timeout: 5))
    attach("dynamic-composer", app: app)
    app.buttons["取消"].tap()
    app.buttons["资料库"].tap()
    for name in ["收藏", "稍后再看", "观看记录", "下载"] {
      app.buttons[name].tap()
      XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
      attach("library-" + name, app: app)
      goBack(app)
    }
    app.buttons["我的"].tap()
    attach("account", app: app)
    app.buttons["设置"].tap()
    attach("settings-top", app: app)
    for _ in 0..<7 {
      if app.buttons["开源许可"].isHittable { break }
      app.swipeUp()
    }
    attach("settings-bottom", app: app)
    app.buttons["开源许可"].tap()
    XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 5))
    attach("licenses", app: app)
  }

  func testPlayerLargeTextAndInteractionSheets() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--qa-ui", "--qa-navigation", "-appearance", "dark",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    XCTAssertTrue(app.buttons["播放详情"].waitForExistence(timeout: 10))
    attach("player-large-top", app: app)
    let coin = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "投币，")).firstMatch
    for _ in 0..<8 {
      if coin.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(coin.isHittable)
    attach("player-large-actions", app: app)
    coin.tap()
    XCTAssertTrue(app.navigationBars["投币"].waitForExistence(timeout: 5))
    attach("coin-sheet-large", app: app)
    app.buttons["完成"].tap()
    let comments = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "评论 "))
      .firstMatch
    for _ in 0..<8 {
      if comments.isHittable { break }
      app.swipeUp()
    }
    comments.tap()
    app.swipeUp()
    attach("player-large-comment-editor", app: app)
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "comment-draft").firstMatch.exists)
  }

  func testCompactConversationComposerEmojiAndStableBottomBar() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "-appearance", "dark"]
    app.launch()
    XCTAssertTrue(app.buttons["消息"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons.matching(identifier: "消息").count, 1)
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
    attach("inbox-liquid-glass-dark", app: app)
    let bottom = app.buttons["资料库"].frame.minY
    for _ in 0..<2 {
      app.buttons["conversation-1:12"].tap()
      XCTAssertTrue(app.buttons["关闭会话"].waitForExistence(timeout: 5))
      XCTAssertGreaterThan(app.navigationBars["测试会话 2"].frame.minY, app.frame.height * 0.15)
      attach("conversation-compact", app: app)
      let emoji = app.buttons["表情"].frame
      let photo = app.buttons["选择消息图片"].frame
      XCTAssertEqual(emoji.height, photo.height, accuracy: 1)
      XCTAssertEqual(emoji.width, photo.width, accuracy: 1)
      XCTAssertEqual(emoji.midY, photo.midY, accuracy: 1)
      app.buttons["表情"].tap()
      XCTAssertTrue(app.buttons["关闭表情"].waitForExistence(timeout: 5))
      attach("emoji-compact", app: app)
      app.buttons["关闭表情"].tap()
      app.buttons["关闭会话"].tap()
      XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
      XCTAssertEqual(app.buttons.matching(identifier: "资料库").count, 1)
      XCTAssertEqual(app.buttons["资料库"].frame.minY, bottom, accuracy: 1)
    }
    app.buttons["动态"].tap()
    app.buttons["发布动态"].tap()
    XCTAssertTrue(app.navigationBars["发布动态"].waitForExistence(timeout: 5))
    XCTAssertGreaterThan(app.navigationBars["发布动态"].frame.minY, app.frame.height * 0.2)
    attach("composer-half-height", app: app)
    app.buttons["取消"].tap()
    XCTAssertEqual(app.buttons["资料库"].frame.minY, bottom, accuracy: 1)
  }

  func testEmojiPopoverDismissesKeyboardAndPreservesDraft() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "-appearance", "dark"]
    app.launch()
    XCTAssertTrue(app.buttons["消息"].waitForExistence(timeout: 10))
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
    app.buttons["conversation-1:12"].tap()
    let input = app.descendants(matching: .any)["message-input"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText("Keep this draft")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.buttons["表情"].tap()
    XCTAssertTrue(app.buttons["关闭表情"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    attach("emoji-after-keyboard", app: app)
    app.buttons["关闭表情"].tap()
    XCTAssertEqual(input.value as? String, "Keep this draft")
    app.buttons["关闭会话"].tap()
  }

  func testVideoFromCompactConversationReturnsToConversationAndStableDock() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-message-video"]
    app.launch()
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
    app.buttons["conversation-1:12"].tap()
    XCTAssertTrue(app.buttons["消息中的视频"].waitForExistence(timeout: 5))
    app.buttons["消息中的视频"].tap()
    XCTAssertTrue(app.staticTexts["player-title"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["player-title"].label, "导航测试视频 A")
    app.buttons["收起播放器"].tap()
    XCTAssertTrue(app.buttons["关闭会话"].waitForExistence(timeout: 5))
    attach("video-returned-to-conversation", app: app)
    app.buttons["关闭会话"].tap()
    XCTAssertTrue(app.buttons["mini-player-open"].waitForExistence(timeout: 5))
    let bottom = app.buttons["资料库"].frame.minY
    for _ in 0..<2 {
      app.buttons["mini-player-open"].tap()
      XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
      app.buttons["收起播放器"].tap()
      XCTAssertTrue(app.buttons["mini-player-open"].waitForExistence(timeout: 5))
      XCTAssertEqual(app.buttons.matching(identifier: "资料库").count, 1)
      XCTAssertEqual(app.buttons["资料库"].frame.minY, bottom, accuracy: 1)
    }
    attach("stable-dock-with-mini-player", app: app)
    app.buttons["关闭播放器"].tap()
  }

  func testNoticeOpensExactCommentAndLocalReplySheet() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui"]
    app.launch()
    app.buttons["消息"].tap()
    app.buttons["inbox-category-1"].tap()
    XCTAssertTrue(app.buttons["查看并回复"].waitForExistence(timeout: 5))
    app.buttons["查看并回复"].tap()
    XCTAssertTrue(app.staticTexts["可以实现一层一层返回吗？"].waitForExistence(timeout: 10))
    app.buttons["回复"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["回复评论"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["回复 @导航测试 UP 主"].exists)
    attach("notice-exact-reply-sheet", app: app)
    let draft = app.textViews["comment-draft"].exists ? app.textViews["comment-draft"] : app.textFields["comment-draft"]
    draft.tap()
    draft.typeText("通知回复测试")
    app.buttons["发送"].tap()
    XCTAssertTrue(app.navigationBars["评论回复"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["回复成功"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["同一条评论下的回复"].exists)
    attach("notice-sent-reply-visible", app: app)
    XCTAssertTrue(app.buttons["本地测试"].exists || app.staticTexts["本地测试"].exists)
    app.buttons["查看原页面"].tap()
    XCTAssertTrue(app.navigationBars["原页面"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.state, .runningForeground)
    app.buttons["完成"].tap()
    XCTAssertTrue(app.navigationBars["评论回复"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["回复成功"].exists)
  }

  func testFullscreenControlsAndHoldWithLocalFixture() throws {
    let fixture = ProcessInfo.processInfo.environment["BILI_IOS_FIXTURE"] ?? "gesture.mp4"
    let app = XCUIApplication()
    app.launchArguments = ["--qa-fixture", fixture]
    app.launch()
    XCTAssertTrue(app.buttons["播放详情"].waitForExistence(timeout: 15))
    app.buttons["播放详情"].tap()
    XCTAssertTrue(waitForValue("rendered-frame-status", "是", app: app))
    app.buttons["完成"].tap()
    // Test the full touch target, including the space outside the small icon glyph.
    app.buttons["全屏"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
    XCTAssertTrue(app.buttons["退出全屏"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["清晰度"].exists)
    let pause = app.buttons["player-play-pause"]
    XCTAssertEqual(pause.value as? String, "正在播放")
    pause.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
    XCTAssertEqual(pause.value as? String, "已暂停")
    XCTAssertTrue(app.buttons["退出全屏"].exists)
    pause.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.85)).tap()
    XCTAssertEqual(pause.value as? String, "正在播放")
    let dm = app.buttons["关闭弹幕"].exists ? app.buttons["关闭弹幕"] : app.buttons["开启弹幕"]
    let old = dm.label
    dm.tap()
    XCTAssertTrue(app.buttons[old == "关闭弹幕" ? "开启弹幕" : "关闭弹幕"].exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 2)
    attach("fullscreen-controls-after-hold", app: app)
    app.buttons["退出全屏"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
    XCTAssertTrue(app.buttons["播放详情"].waitForExistence(timeout: 5))
    app.buttons["播放详情"].tap()
    XCTAssertTrue(waitForValue("temporary-speed-status", "未启用", app: app))
  }

  func testEmojiPackageSwitchResetsScroll() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui"]
    app.launch()
    app.buttons["消息"].tap()
    app.buttons["conversation-1:12"].tap()
    app.buttons["表情"].tap()
    XCTAssertTrue(app.buttons["[组1-1]"].waitForExistence(timeout: 5))
    attach("emoji-before-scroll", app: app)
    let first = app.buttons["[组1-1]"]
    first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2)).press(forDuration: 0.1, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -2)))
    app.buttons["emoji-package-picker"].tap()
    app.buttons["表情组 2"].tap()
    XCTAssertTrue(app.buttons["[组2-1]"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["[组2-1]"].isHittable)
    attach("emoji-new-package-top", app: app)
  }

  func testLandscapeAutomaticallyPresentsFullscreen() throws {
    if ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" {
      throw XCTSkip("The installed iPhone Duo runtime does not deliver physical rotation; verify automatic fullscreen on iPhone hardware.")
    }
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    app.launchArguments = ["--qa-ui", "--qa-navigation"]
    app.launch()
    XCTAssertTrue(app.buttons["全屏"].waitForExistence(timeout: 10))
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.buttons["退出全屏"].waitForExistence(timeout: 10))
    attach("landscape-auto-fullscreen", app: app)
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.buttons["全屏"].waitForExistence(timeout: 10))
  }

  private func goBack(_ app: XCUIApplication) {
    if app.buttons["BackButton"].exists {
      app.buttons["BackButton"].tap()
    } else {
      app.navigationBars.buttons.firstMatch.tap()
    }
  }

  private func checkMiniPlayer(_ app: XCUIApplication) {
    app.buttons["收起播放器"].tap()
    XCTAssertTrue(app.buttons["关闭播放器"].waitForExistence(timeout: 5))
    app.buttons["资料库"].tap()
    XCTAssertTrue(app.buttons["关闭播放器"].exists)
    attach("mini-player", app: app)
    app.buttons["关闭播放器"].tap()
    XCTAssertFalse(app.buttons["关闭播放器"].exists)
  }

  private func attach(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func waitForValue(
    _ id: String, _ value: String, app: XCUIApplication, timeout: TimeInterval = 20
  ) -> Bool {
    let element = app.descendants(matching: .any)[id].firstMatch
    guard element.waitForExistence(timeout: 5) else { return false }
    return XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", value), object: element)
      ], timeout: timeout) == .completed
  }
}
