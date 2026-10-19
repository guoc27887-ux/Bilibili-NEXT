# Third-party components

BiliKit-Mac by shiinayane, MIT license, pinned at `0d6cb46db6bfc3b54020f3cb20b46c92d5395c4a`.
Source: https://github.com/shiinayane/BiliKit-Mac

The `Vendor/BiliKitCore` directory contains the BiliModels, BiliApplication, BiliNetworking and BiliPlayback modules and playback tests. Original license: `Vendor/BiliKitCore/LICENSE`. A `BiliGlassBridge.swift` adapter exposes the existing DASH bridge and accepts the app's bounded parallel video streamer. The vendor manifest only builds these modules. Local changes add explicit VIDEO-RANGE / SUPPLEMENTAL-CODECS attributes, optional in-memory initialization segment overrides for Dolby Vision compatibility brands, and corresponding bridge routing. The media streaming client exposes a bounded per-host connection limit (default unchanged for upstream callers), while BiliGlass applies its own shared adaptive video limit. Small bounded requests use a bounded pending buffer instead of suspending for every chunk. Transport errors drain already accepted callbacks before propagating, preventing suffix retries from racing prior delivery. Original notices are retained. No upstream branding or artwork is included.

The app UI, API adapter, session storage, download manager and playback lifecycle are implemented separately for Bilibili NEXT.

References consulted, no code copied:
- Bilibili-thread-ripper (MIT), commit `ee3adaa8cc1afbb29a3d7153e1295e09e42b29e2`: https://github.com/MrTangLuyao/Bilibili-thread-ripper — partial-prefix resume, bounded pieces, shared connection scheduling and CDN recovery informed the independent Swift implementation. The Electron UI and downloader JavaScript are not bundled.
- IINA / mpv architecture: https://github.com/iina/iina
- IINA+ DASH representation model: https://github.com/xjbeta/iina-plus
- Video interactions and favorite-folder API reference: https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/video/action.md and https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/fav/info.md
- bilibili-API-collect API documentation: https://github.com/pskdje/bilibili-API-collect
- Official BAS language specification (independent Swift parser and native renderer; no JavaScript runtime or implementation copied): https://bilibili.github.io/bas/ and https://github.com/bilibili/bas
- DanmakuFlameMaster mode 7 data format reference (no implementation copied): https://github.com/bilibili/DanmakuFlameMaster
- Apple Liquid Glass: https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views

This is an unofficial client. Bilibili names, videos, thumbnails and account data belong to their respective owners.
