# Contributing

Use macOS 26 or later, Xcode 26 or later, and Swift 6.2 or later. The app uses
native SwiftUI, AppKit and AVPlayer; preserve text input, accessibility and
keyboard behavior when changing controls.

```sh
swift test
swift test --package-path Vendor/BiliKitCore
Scripts/build-app.sh
```

Live API tests are disabled by default and require explicit local test flags.
Do not add account credentials, signed media URLs, private messages or user
media to fixtures. Playback changes should be exercised with a rendered video,
not just a successful parser or AVPlayer ready status. Include quality changes,
seek, fullscreen, pause/resume, download completion and temporary-file cleanup
when those paths change.

Retain the upstream license and identify modifications to vendored code in
THIRD_PARTY.md. New dependencies need a clear compatible license and provenance.

Release packaging uses `Scripts/package-release.sh` after all source changes are
committed. It creates signed-app ZIP, DMG, committed-source ZIP and SHA-256 sums.
Use your own `SIGNING_IDENTITY` as appropriate. This does not perform notarization.

For the iOS / iPadOS preview, use Xcode 27+ (deployment target iOS 26+), clone the
whole repository, and run `Scripts/build-ios.sh` for an unsigned simulator build.
Open `Apps/iOS/BilibiliNEXT.xcodeproj` and use the shared `BilibiliNEXT` scheme for
development and UI tests. Device signing uses your own `DEVELOPMENT_TEAM`; do not
commit provisioning profiles, certificates, local account data or Xcode user state.
See `IOS_STATUS.md` for current support and validation limits. Regenerate the
project with `python3 Scripts/generate-ios-project.py` after changing its source list.
See `Assets/ICON.md` for SVG icon editing and resource generation.
