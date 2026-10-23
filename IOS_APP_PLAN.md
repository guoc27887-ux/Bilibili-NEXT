# Bilibili NEXT：iOS / iPadOS 完整迁移计划

源码审阅日期：2026-10-21。本文是实施计划，不表示已经创建、构建或验证 iOS App。

## 1. 结论与范围

建议新增原生 iPhone / iPad App，使用 SwiftUI + UIKit + AVFoundation，保留原生 Liquid Glass 风格，并逐项迁移当前 macOS 客户端的页面和功能。业务与播放基础组件共享，导航、触控播放器、弹幕承载视图和系统集成按平台实现。

“完整”以本项目当前工作区为基准，包括尚未提交的功能；不是只复刻公开发布版，也不等于实现哔哩哔哩官方客户端的全部服务。本文下面的功能编号是迁移与验收清单，不能因为阶段划分而从最终范围移除。

推荐首版最低 iOS / iPadOS 26，以直接使用项目现有的 Liquid Glass API；这是方案建议，尚未建立 Deployment Target。若需要支持更旧系统，应另增材质降级和兼容测试工作。当前本机已读取到 Xcode 27.1、iPhoneOS SDK 27.1，具备开始建工程的工具链；签名、设备安装、模拟器和真机运行尚未验证。

### 当前源码基线

- 顶层和 Vendor 的 `Package.swift` 都只声明 macOS 26；当前没有 iOS App target 或 Xcode 工程。
- 应用目录包含 62 个 Swift 文件、约 12,662 行；Vendor 源码包含 89 个 Swift 文件，应用测试目录有 19 个测试文件。这些数量表示源码规模，不表示测试通过数。
- HEAD 为 `11c10ec`，审阅时工作区有 36 个修改/未跟踪条目。新增功能位于工作区，后续实施前必须重新核对差异，不可以只从该提交导出旧版本。
- 现有打包脚本生成 macOS `.app`、ZIP 和 DMG，不能直接用来生成 iOS 安装包。
- 本次依据源码、README、QA 和构建配置进行静态审阅；没有构建 iOS，也没有把文档记载的 macOS 验证当作 iOS 验证。

## 2. 手机和平板的完整 UI 结构

### iPhone 主导航

采用五个 Tab，每个 Tab 保留自己的导航栈、滚动位置和筛选状态：

| Tab | 一级页面 | 二级页面与入口 |
| --- | --- | --- |
| 首页 | 推荐、热门、分区 | 搜索、搜索筛选、用户结果、视频播放、UP 主主页、推荐反馈、举报 |
| 动态 | 关注动态 | 动态详情、动态评论、图片浏览、发布/转发动态、UP 主主页 |
| 消息 | 私信、回复我的、@ 我的、收到的赞、系统通知 | 会话详情、历史消息、图片浏览、视频卡片、验证面板 |
| 资料库 | 收藏、稍后再看、观看记录、下载 | 收藏夹选择/编辑、批量管理、账号/本机历史、离线播放、导出文件 |
| 我的 | 自己的主页、账户摘要 | 投稿、关注/粉丝、合集、账户信息、黑名单、设置、更多官方服务、登录/退出 |

全局搜索通过顶部按钮进入独立搜索页面，支持关键词、BV 号和视频链接；标签搜索及个人主页入口均复用同一路由。

播放详情使用可恢复的全局播放会话。离开播放详情后显示位于 Tab 栏上方的紧凑迷你播放器，包含画面、标题、播放/暂停、返回和关闭；不能挡住列表底部和输入框。切换 Tab 不重建 AVPlayer。

### iPad 导航

宽屏使用 `NavigationSplitView`，保留当前 11 个目的地：推荐、热门、分区、关注动态、消息、观看记录、收藏、稍后再看、下载、我的主页、更多。紧凑宽度回到与 iPhone 一致的导航。

会话采用列表/详情双栏；播放页在足够宽时采用视频/评论或视频/信息的自适应布局。分屏、窗口尺寸变化和横竖屏切换均不能触发重新起播或丢失输入草稿。多窗口不作为首版新增承诺，需避免两个 Scene 同时争夺全局播放状态。

### 播放详情与横屏全屏

竖屏从上到下：视频画面 → 进度与主控制 → 标题/作者/发布时间 → 点赞投币收藏分享 → 简介/分 P/合集/标签 → 简介与评论切换内容。操作较多的清晰度、倍速、字幕、章节、播放顺序、下载、弹幕管理和播放详情进入菜单或底部面板，保持全部入口可达。

横屏全屏：同一 AVPlayer 继续播放，安全区域内显示返回、标题、播放状态、进度、播放/暂停、清晰度、倍速、字幕、弹幕开关、设置和更多。弹幕输入与键盘采用独立面板；收起键盘不退出全屏。竖屏视频按原始比例显示，不能强制裁成 16:9。

### 统一视觉与交互

- 保留粉色选中提示、系统前景色、通透/柔和玻璃、深浅色和自定义背景；导航与操作层使用玻璃，长文本和评论保持可读。
- 手机卡片按可用宽度选择单列或双列；大字体下可回落单列。移除现有 1020 / 900 / 820 等桌面最小宽度，以及固定宽高弹窗。
- 原有右键菜单映射为长按菜单和显式“更多”按钮；鼠标 hover 的进度缩略图映射为拖动预览。手机主路径不依赖 hover 或键盘。
- 所有面板支持安全区域、键盘避让、内容滚动、Dynamic Type、VoiceOver、减少动态效果及降低透明度。
- 清晰度切换、分页、图片上传、验证和写操作都显示进行中/失败/重试状态；失败刷新保留已有内容。

## 3. 页面与功能逐项覆盖表

“保留”指纳入 iOS 实施与最终验收；当前有源码实现不代表接口在所有账户、地区或设备上可用。

### A. 启动、账号、浏览与搜索

| 编号 | 当前源码入口 | 必须迁移的 UI 与功能 | iOS 实现与验收重点 |
| --- | --- | --- | --- |
| A01 | `BiliGlassApp`、`RootView`、`Store` | 启动、恢复登录、首页快照、导航、全局提示、刷新 | 新 App/Scene 生命周期；游客可浏览；账号切换不串数据；旧请求不覆盖新状态 |
| A02 | `LoginSheet`、`Store.refreshQR`、`Vault` | 二维码、轮询、扫码状态、过期刷新、关闭登录、钥匙串存储、退出 | 保留二维码路径；先验证同机可用的官方登录路径，见风险表；不读取其他 App 凭据 |
| A03 | `OfficialWebPanel`、`WebSession` | 官方验证、Cookie 同步、验证结束返回、外部链接 | `WKWebView` 的 UIKit 包装；限制导航域名；退出时清理应用 Web 会话；不得转发 Cookie 到外部域名 |
| A04 | `RootView.browse`、`API`、`Community` | 推荐、热门、封面、标题、作者、时长、播放量、分页、刷新 | 自适应卡片和下拉刷新；已有列表复用、去重、空态、失败保留与自动加载开关 |
| A05 | `Regions` | 31 个主分区、分区视频 | 分区选择页或可折叠网格；迁移当前启用的主分区，不把数据中的未启用子分区当成已支持 |
| A06 | `Store.search`、`SearchFeatures` | 关键词/BV/视频链接、视频/用户切换、搜索历史清空、联想 | 独立搜索 UI、取消过期联想、键盘提交、用户卡片进入主页；不默认读取剪贴板 |
| A07 | `SearchFilters` | 综合/最多播放/最新/最多弹幕/最多收藏；时长；最近一天/一周/半年 | 筛选底部面板；应用后重置分页，保留已选项和清除入口 |
| A08 | `VideoContextActions`、`ContentModeration` | 播放、稍后再看、复制链接、官方打开、推荐反馈、视频举报、拉黑 | 长按及更多菜单；举报原因/补充文字/提交结果；拉黑确认；不通过隐藏手势承载唯一入口 |

### B. 播放、媒体传输与播放页

| 编号 | 当前源码入口 | 必须迁移的 UI 与功能 | iOS 实现与验收重点 |
| --- | --- | --- | --- |
| B01 | `Playback`、`NativePlayer` | AVPlayer 出画、音画播放、加载/缓冲/失败/恢复、实际格式显示 | UIKit 播放表面；DASH → 本机 HLS 链路先做真机验证；失败可重试，禁止靠“ready”判定成功 |
| B02 | `PlayerControls`、`PlayerKeyboard` | 播放暂停、时间、精确拖动、音量、快进退、临时倍速 | 主控制触摸可用；双击画面两侧 ±5 秒、长按临时倍速；松手/来电/切后台恢复原速；在线 2×/本地可用时 3× 的边界明确 |
| B03 | `FullscreenPlayer`、`MiniPlayer` | 内嵌/全屏/迷你之间连续播放、返回、关闭才停止 | 一个播放会话；旋转、交互式返回和 Tab 切换不重复发起媒体请求；迷你播放器可访问 |
| B04 | `Playback.selectQuality`、`API.streams` | 清晰度、0.5–2× 常规倍速、编码筛选、HDR/杜比、高分辨率 | 按视频/账号/设备实际能力显示；切换保留分 P、进度、暂停/播放状态；8K/HDR/杜比逐设备验证 |
| B05 | `Store`、`Playback.restoredPosition` | 每个分 P 恢复、近片尾从头、自动播放开关 | 恢复记录与当前账号对应；播放成功后才推进记录；关闭恢复时不偷偷 seek |
| B06 | `PlayerPage`、`VideoExtras` | 标题、UP、BV、发布时间、简介、分 P、相关推荐、标签 | 移动排版、文字选择/复制、标签搜索；相关推荐、UP 及分 P 的点击路径完整 |
| B07 | `VideoExtras`、`Store.playQueue` | 合集与资料库队列、当前项标记、下一集、自动下一集、单集循环 | 队列底部面板；同视频不同 CID 正确标识；迷你状态自动下一集不抢走导航 |
| B08 | `VideoExtras`、`SubtitleOverlay` | 字幕列表、切换/关闭、字幕错误；章节跳转 | 前台字幕与弹幕避让；PiP 使用可行的原生字幕轨道方案，不能假设 SwiftUI 字幕会自动进入 PiP |
| B09 | `VideoPreview`、`PlayerControls` | 雪碧图进度预览、时间、不可用提示、缓存 | 拖动时预览；有界解码内存；快速拖动取消过期图片；贴边不超出屏幕 |
| B10 | `PlaybackDetails` | CDN、编码、码率、帧率、速度、缓冲、并发、峰值、换线/补传 | 可滚动的播放详情面板，打开不暂停；脱敏导出不包含 Cookie 或完整签名 URL |
| B11 | `CDNSelection`、`ParallelVideoStream`、Vendor | Range 流式读取、择优 CDN、备用身份校验、补传、超时、并发退让/恢复 | 共享传输逻辑；弱网/断连/换网/取消/重载验证；已交付字节不重复、不遗漏 |
| B12 | `PlaybackDiskCache`、`PlaybackTemporaryFiles` | 持续预读、1–32 GB 上限、低空间降级、临时与永久缓存隔离 | 使用 iOS 沙盒；移动网络/低电量策略可见；内存警告清内存缓存；不能依赖终止回调清理 |
| B13 | 现有“画中画…”入口 | 系统 PiP 与恢复播放页 | 使用 AVKit 正式接入；先验 loopback 媒体在后台的持续供给；PiP、前台和迷你互斥协调 |

### C. 弹幕

| 编号 | 当前源码入口 | 必须迁移的 UI 与功能 | iOS 实现与验收重点 |
| --- | --- | --- | --- |
| C01 | `Danmaku`、`DanmakuTextBitmap` | 滚动、反向、顶部、底部、字形描边和调度 | CoreText/CoreGraphics + UIKit/CALayer；使用 iOS 刷新回调；暂停、隐藏、空档停更新 |
| C02 | `SpecialDanmaku`、`BAS`、`SVGPath` | mode 7 定位；mode 9 BAS 文字/路径/模板/父子/串并行动画/变换 | 保留解释器和几何，替换字体/颜色/视图；同视频同时间检查方向、比例、暂停与回拖重建 |
| C03 | `DanmakuComposer` | 开关、发送、当前位置、滚动/顶部/底部、字号、七种颜色、发送错误与高级加载提示 | 输入面板；100 字限制；捕获提交时样式/时间；防重复提交，不接管输入法手势 |
| C04 | `DanmakuSettings`、`Preferences` | 不透明度、区域、字号、滚动时长；滚动/顶/底/彩色过滤、字幕避让、去重、本机屏蔽词 | 播放页快速面板 + 设置全项；变更实时生效；高级布局保留作者语义 |
| C05 | `DanmakuManagement` | 已加载列表、搜索、数量、点时间跳转、屏蔽文字/发送者、举报 | 手机列表及行菜单；举报原因和结果；不把已加载数量显示成全部弹幕量 |
| C06 | `DanmakuManagement` | 历史月份/日期、读取历史、恢复当前弹幕 | 日期选择适配手机；账号/视频切换取消旧响应；离线状态解释不可用原因 |
| C07 | `DanmakuCloudRule` | 云端关键词/正则/发送者规则、添加/删除/同步、账号隔离 | 共享 API；规则列表和编辑页；只将成功同步结果落盘 |
| C08 | `PersonAvoidance` | 可选本机人物分割、防挡遮罩、默认关闭 | Vision 工作器复用、承载视图解耦；按能耗/热状态降采样；不上传画面，停播及不可见时停止 |

mode 8 可执行代码弹幕当前未支持，iOS 保留清晰提示；不新增任意脚本执行。复杂 BAS 的兼容差异必须继续列在 QA 中。PiP 不能直接继承应用内的弹幕叠层，见第 6 节。

### D. 视频互动、评论与图片

| 编号 | 当前源码入口 | 必须迁移的 UI 与功能 | iOS 实现与验收重点 |
| --- | --- | --- | --- |
| D01 | `VideoActionBar`、`VideoActions` | 点赞/取消及状态、点赞投币收藏分享计数 | 图标/文字按钮布局；未登录引导；防重入；服务端成功后更新 |
| D02 | `CoinSheet` | 1/2 枚、余额/已投数量、版权限制、同时点赞、验证 | 底部确认面板；禁用原因可见；扣币不可撤回；网络结果不确定时先读状态，不能自动重试 |
| D03 | `TripleSheet` | 三连确认、默认收藏夹、部分成功结果、验证 | 单次提交；分别保留服务端确认结果，不能将三项合成一个本地成功布尔值 |
| D04 | `FavoriteSheet` | 多收藏夹选择、取消收藏、新建公开/私密夹 | 保存才应用收藏变化；创建夹立即提交的时机明确；失败保留选择 |
| D05 | `VideoShareSheet` | 复制链接/BV、二维码、带分 P/时间、系统分享 | `ShareLink` 或系统分享面板；干净链接；二维码用 CGImage/UIImage；无 Cookie/跟踪参数 |
| D06 | `Comments`、`CommentsView` | 热门/最新、总数/已加载、游标分页、自动加载、失败保留 | 懒加载列表；重复游标重试；不能以短页判断结束；视频切换取消旧加载 |
| D07 | `ReplyRow`、`Comments` | 楼中楼、展开/加载/收起、长文本展开、回复、点赞、删自己的评论、时间与 IP 属地 | 手机独立回复详情可复用模型；子回复合并、列表位置稳定；删除保留确认 |
| D08 | `Comments.send`、`EmojiPicker`、`ImageUpload` | 正文/回复草稿、表情、最多九张图片、1000 字限制、上传/发送错误、验证 | 相册/文件选图；后台返回保留草稿；提交记录与“公开显示”区分；不自动重发 |
| D09 | `CommentText`、`CommentVideoLink`、`MessageShare` | 富文本表情、组合表情、选择复制、BV/AV/b23 视频卡片 | CoreGraphics 图片桥接；白名单短链解析、不转发登录；卡片进入原生播放器 |
| D10 | `ImageGallery`、`NativeImageCanvas` | 原图加载、缩放、切换、保存、错误反馈 | UIKit 缩放容器或验证过的 SwiftUI 手势；保存相册/文件、系统分享；跟随减少动态效果 |

表情动画当前显示静态帧；iOS 完整迁移仍以此为现有能力，不能把动态表情播放列为已复用功能。

### E. 动态、私信和通知

| 编号 | 当前源码入口 | 必须迁移的 UI 与功能 | iOS 实现与验收重点 |
| --- | --- | --- | --- |
| E01 | `NativeDynamicsPage`、`DynamicContent` | 关注动态、某 UP 动态、文字/图片/视频/转发内容、刷新与分页 | 卡片自适应；图片进图库，视频进播放器；动态详情复用内容与评论 |
| E02 | `DynamicActions`、`NativeDynamicDetail` | 点赞/取消、转发、评论数、动态评论 | 与视频评论区分资源类型；结果确认后更新；失败保留内容 |
| E03 | `DynamicComposer`、`DynamicDraft` | 发文字/图文、最多九图、表情、2000 字、转发附言、AI 内容标记 | 全屏编辑页；上传进度、移除附件、失败草稿；发布中防重复和误关闭 |
| E04 | `NativeInboxPage`、`InboxModel` | 会话分页、姓名搜索、头像、预览、未读、选择与已读 | iPhone 列表→详情，iPad 双栏；服务端时间戳游标；重复分页和失败提示 |
| E05 | `ConversationTimeline` | 历史消息、每会话滚动位置、向上加载保持阅读锚点 | 键盘/图片尺寸变化不跳位置；会话切换还原当前位置；新消息不强行打断历史阅读 |
| E06 | `Messaging`、`InboxViews` | 文字收发、表情、图片发送/显示、视频分享、复制、两分钟内撤回、草稿 | 系统选图与发送确认；撤回后去除分享内容；视频卡片兼容 BV/AV；结果不明不重发 |
| E07 | `NativeNotificationsPage` | 回复我的、@ 我的、收到的赞、系统通知、内容跳转、分页与错误 | 分类页面适配；有可解析视频时内部播放，否则受控官方链接；不将站内消息功能等同于 APNs 推送 |

### F. 资料库、个人主页与更多

| 编号 | 当前源码入口 | 必须迁移的 UI 与功能 | iOS 实现与验收重点 |
| --- | --- | --- | --- |
| F01 | `LibraryToolbar`、`Store` | 收藏夹列表/计数、搜索当前夹、播放列表 | 手机夹列表→视频列表；搜索更换分页；整表播放使用当前队列规则 |
| F02 | `LibraryManager`、`FavoriteFolderEditor` | 编辑名称/简介/隐私、删除夹、批量复制/移动/移除、选择已加载视频、部分成功提示 | 编辑与多选工具栏；删除确认；仅选已加载内容，不能暗示全服务端全选 |
| F03 | `LibraryManagement` | 稍后再看列表、搜索、加入/移除、选择已看完并清理 | 当前数据源与播放队列共享；批量失败保留未完成项 |
| F04 | `AccountHistory`、`HistoryPage`、`WatchHistorySync` | 账号/本机切换、合并去重、最近分 P/进度、账号分页、本机清空、约30秒同步、暂停/离开提交 | 分账号隔离；离线也记本机；清本机不删远端；失败保留；不依赖退出时网络提交 |
| F05 | `ProfilePage` | 头像、UID、简介、关注/粉丝/投稿、投稿列表、关注/取消、发私信、自己的资料库入口 | 共用个人/他人主页；跳转后保持来源页位置；关注失败不先显示成功 |
| F06 | `NativeRelationsPage` | 关注列表、粉丝列表、分页、进入个人主页 | 单独列表页；加载失败可重试；不擅自扩展为完整关注管理工具 |
| F07 | `NativeCollectionsPage`、`NativeCollectionVideos` | 合集/系列列表、视频列表、分页与播放 | 复用播放队列；合集及系列标识不能冲突 |
| F08 | `NativeAccountPage` | 等级、硬币、大会员状态、账户管理、设置、退出 | 只展示服务端数据；账户管理走官方链接；不增加充值或购买实现 |
| F09 | `BlockedAuthorsPage` | 黑名单分页、解除屏蔽 | 我的→黑名单；解除成功后更新列表；账号退出取消加载 |
| F10 | `WebFunctionsPage` | 更多入口、创作中心、番剧、直播 | 保留官方打开方式并标明；当前源码没有原生番剧/直播/创作中心，不能在迁移计划中算作现成原生功能 |

### G. 下载、离线和设置

| 编号 | 当前源码入口 | 必须迁移的 UI 与功能 | iOS 实现与验收重点 |
| --- | --- | --- | --- |
| G01 | `Downloads`、`DownloadPage` | 应用缓存/外部保存、全部/缓存/外部筛选、进度/状态/错误、任务角标、暂停继续移除 | 前台调度复用；iOS 后台传输另建执行器；进行中/完成行身份独立 |
| G02 | `DownloadPiece`、`ParallelMediaDownload` | 多任务、多连接、分块续传、残块前缀、地址刷新、媒体身份校验 | 前台连接 1–32、同时任务 1–3 的设置保留；后台由系统调度，不能虚报完全控制并发 |
| G03 | `DownloadPublication`、`NativeComposition` | 合轨、轨道校验、检查点、同内容复用、同名保护、完成落盘 | 分离下载完成/合轨完成/已保存；后台时间不足显示待处理，恢复执行不损坏文件 |
| G04 | `SavedDownload`、`MP4Compatibility` | 已完成管理、离线播放、hev1 兼容副本、文件不存在、移除记录、删除缓存 | 原始文件保留、生成兼容副本；iOS 删除确认代替废纸篓；文件权限与重启验证 |
| G05 | `Downloads.saveDanmaku` | 自动 JSON/XML 弹幕、本地 JSON 离线弹幕、单独 XML 导出 | 文件导出替代保存面板；视频与 sidecar 状态分别显示；既有失败记录见第6节 |
| G06 | `AppPaths`、`Preferences` | 自定义缓存位置、查看文件、外部保存与定位 | 内部沙盒稳定存储；“存储管理/导出/在文件中查看”替代 Finder；选择目录须安全作用域与 bookmark，不能保存裸绝对路径 |
| G07 | `PreferencesView`、`GlassStyle` | 跟随/浅/深、通透/柔和、动画、背景选择/默认/模糊/可见度 | 原生分组设置页；相册或文件导入背景；后台生成模糊缓存，不每帧处理 |
| G08 | `PreferencesView` | 自动播放、恢复进度、同步、自动加载、默认评论排序、前向缓冲、预读、容量、播放/下载并发 | 所有现有选项可达；增加移动数据与低电量策略说明；改变何时生效明确 |
| G09 | `PreferencesView` | 弹幕完整设置、下载同时保存弹幕、缓存目录、缩略图缓存清理、本机记录清理 | 清理各类数据边界明确；不连带删除手动保存媒体或账号数据 |
| G10 | 设置关于、`THIRD_PARTY`、`Diagnostics` | 版本、许可/来源、限制说明、诊断能力 | iOS 诊断页/测试入口代替 Mac 命令行窗口采集；日志脱敏；许可和图标资源进入 App bundle |

## 4. 代码复用与工程结构

建议保持同一仓库，新增 iOS App 工程，先将平台无关逻辑抽成库，再让 macOS 与 iOS 分别引用。不要让 iOS target 依赖现有 macOS executable target。

```text
Apps/
  iOS/                  SwiftUI App、Info.plist、资源、签名配置
Packages/
  BiliClientCore/        API、认证、模型、分页、账号会话、业务写入
  BiliMedia/             播放会话、CDN、Range、缓存、离线与下载状态机
  BiliDanmaku/           解析、BAS、几何、时间调度、CoreText 绘制数据
  BiliUI/               平台中立卡片、富文本、主题与通用状态视图
Platform/
  iOS/                  播放承载、PiP、UIKit 弹幕视图、文件/相册、音频会话
Sources/BiliGlass/      现有 macOS App，渐进接入共享库
Vendor/BiliKitCore/     保留来源与本地修改记录
Tests/                  共享逻辑、平台集成、UI 测试与素材索引
```

这是目标结构，可以按阶段迁移，避免一次搬动所有文件。现有测试依赖 executable target，抽库时需同步调整测试依赖，保持 macOS 基线可运行。

### 可优先复用

- Vendor 的 BiliModels、BiliNetworking、BiliApplication 及 DASH/HLS/SIDX/Range 等基础逻辑。必须先加 iOS 平台并实际编译；若直接引用 BiliApplication，应增加公开 library product 或明确模块边界。
- API 参数、WBI/CSRF、URL 域名策略、媒体表示、评论解析、游标、收藏变更、私信解析、历史合并等业务逻辑。
- CDN 校验与补传、分块状态、下载事务、文件摘要、播放进度、弹幕 protobuf/XML/BAS 解析、SVG 几何和预览图片裁剪。
- `CGImage` 级缩略图和图片处理；分离 macOS 的 NSImage 转换后共享。

这些是复用候选，不给出未经 iOS 编译证明的“可直接复用百分比”。

### 必须解耦或改写

| 当前耦合 | iOS 方向 |
| --- | --- |
| `BiliGlassApp` 的 NSApplicationDelegate、Window、Settings 和菜单命令 | SwiftUI App + UIApplication 生命周期/scenePhase；设置作为 App 内页面 |
| `Store` 同时管理导航、NSImage 二维码、全屏控制、业务状态 | 分离 AppSession、Router、PlaybackSession 与各功能模型；二维码保留 CGImage 数据 |
| `NativeVideoView` / `AVPlayerView` / `NSViewRepresentable` | UIKit 播放容器，基于 AVPlayerLayer 自绘控制并接 PiP；必要时使用 AVPlayerViewController 适配器 |
| NSWindow 全屏、NSEvent 快捷键与焦点 | Scene 方向与全屏呈现、触摸手势、外接键盘命令；编辑状态优先 |
| NSView 弹幕、NSFont/NSColor/NSShadow、窗口可见性通知 | UIView/CALayer + CoreText/CoreGraphics、CADisplayLink 和 Scene/视图可见性 |
| 人物防挡直接引用 NativeVideoView | 播放帧源与遮罩目标协议，Vision 工作器保持独立 |
| NSImage 文本表情、NSScrollView 图库 | UIImage/CGImage、SwiftUI Text 或文本承载适配器、UIKit 缩放容器 |
| NSOpenPanel/NSSavePanel、Finder、NSWorkspace、NSPasteboard | PhotosPicker、文件导入导出/UIDocumentPicker、OpenURL、系统分享和剪贴板 |
| 桌面诊断的 NSWindow、键盘监听、命令行参数 | iOS 诊断入口、os.Logger、XCTest 和真机 Instruments |

播放器采用一个 `PlaybackSession` 持有 AVPlayer、媒体身份、当前 CID、进度、队列和传输任务；视图只负责呈现和用户操作。全屏、迷你、PiP 不各自创建播放器。接入阶段先实现稳定出画，再组合自绘控制和弹幕，避免把视图重建与媒体生命周期绑在一起。

Vendor 中存在如 `#available(macOS 27.0, *)` 的判断，不能在加 iOS 平台后就认为语义正确；应逐项核对 iOS 的 API 可用性。Vendor 的响度均一化等能力未在当前 App 中接入的，不自动算作现有 App 功能；仅保证依赖能正确编译，不额外承诺 UI。

## 5. iOS 系统适配

### 播放与生命周期

- 配置 `AVAudioSession` 的媒体播放类别与合适的 Background Modes；来电、Siri、耳机拔出、蓝牙切换、锁屏和恢复均纳入状态机。依据 Apple 的[媒体播放配置说明](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback)。
- `onDisappear` 不能直接沿用当前根视图的“停止全部播放”行为：导航离开只转迷你；进入 PiP 继续；用户关闭播放才释放会话。
- 保存进度和任务检查点放在持续操作与 Scene 转换中；启动清理无活动租约的临时目录，不依赖系统一定调用退出函数。
- 预读和人物分割按热状态、低电量和网络类型调整。保留现有设置，但首次移动端默认值需实测，不能直接把 8 GB 全片预读和高并发视为适合所有 iPhone。
- 系统音量使用正式系统控件；保留播放器内音量/静音意图，但不使用私有 API 强改设备音量。
- 锁屏媒体信息和耳机/控制中心播放命令作为 iOS 集成项实现；不把后台音频模式用于维持无关任务。

### 下载与存储

现有前台 Swift Task + 分块 Range 不能直接承诺在 iOS 挂起后继续执行。独立设计下载执行器：

1. 前台复用分块与 CDN 校验逻辑；持久化任务 ID、媒体身份、目标、完成区间和已收前缀。
2. 后台使用 `URLSessionConfiguration.background` 与下载任务，向系统提交可恢复的文件传输；确定合理分块粒度，避免把前台 1 MiB 小请求原样变成大量后台任务。
3. App 被系统重新唤醒后，通过 session identifier 和 taskIdentifier 重建状态、接收文件、检查身份，再安排合轨与发布。
4. 媒体 URL 过期、需要刷新认证或合轨超出可用执行时间时，显示“等待打开应用继续处理”，不得假装已经完成。
5. 用户强制退出、后台受限、低空间和系统调度延期分别说明。Apple 指出后台 session 可在挂起时传输，但用户强制退出后系统不会自动重新启动 App：[后台下载](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)、[后台 session 配置](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))。
6. 内部离线媒体放在稳定的 Application Support 区域，排除不必要的云备份；可再生成的缩略图/临时预读放 Caches。索引使用相对路径，防止容器路径变化。
7. 外部目录访问通过用户选择与有效的安全作用域；权限失效时重新授权或导出。外部保存先在沙盒完成，再导出；大文件应避免不必要的双份磁盘占用。

### 登录、权限与安全

- 保留 Keychain 会话隔离和账号代次机制，iOS 独立 bundle 身份；不承诺 Mac/iPhone 自动共享登录。
- 二维码能展示不等于同机登录可用：必须验证官方网页登录/验证是否可在 App 内完成；保存二维码再经官方 App 相册扫码只作为待验证候选。保留第二设备扫码途径，并明确操作条件。
- PhotosPicker 导入评论/私信/动态图片和背景；HEIC 等手机常见输入如需转换，显式转换到当前接口接受的格式并检查体积/尺寸/方向。不能因为 Mac 只选 JPEG/PNG/WebP/GIF 而让 iPhone 常用照片无法选择。
- 保存到相册按需请求添加权限；文件导入导出走系统选择器。不为已有功能预先申请摄像头、麦克风、推送或完整相册访问。
- loopback 只绑定本机、保留随机会话路径；ATS 例外限定本机用途，不新增全局允许 HTTP。局域网权限需求应按实际链路核对，不能把 127.0.0.1 自动当作访问其他局域网设备。
- WebKit 仅用于官方登录/验证；共享、上报和日志均不带登录 Cookie、私信正文或完整媒体签名地址。

## 6. 必须先解决的可行性问题

| 问题 | 当前证据/限制 | 实施前验证与决策 |
| --- | --- | --- |
| DASH → loopback HLS | 源码通过 NWListener 绑定 127.0.0.1；Mac 可用不等于 iOS 后台可用 | 第一阶段真机测试起播、seek、切清晰度、锁屏、PiP、网络切换；有问题先调整媒体供应链路，再批量迁移页面 |
| PiP 与弹幕/字幕 | 前台弹幕和字幕是应用自绘叠层 | 原生 PiP 以视频为基本保证，字幕优先转换为原生 HLS/WebVTT 轨；自绘弹幕不能假设自动出现。若要求 PiP 也显示弹幕，需单独验证 sample-buffer 合成路线、HDR、功耗和音画同步，未通过不能声称全等 |
| 同一部手机登录 | 现有实现面向电脑显示二维码 | 做可完成的官方登录体验；验证码由用户处理，不假定任意 Web 登录都能取得可用会话 |
| 后台下载和合轨 | 当前执行器以进程持续运行作为前提 | 用真实 CDN 的 Range、URL 有效期和 background session 验证；传输/校验/合轨/导出分别持久化并显示状态 |
| HDR/杜比/8K/AV1 | 当前视频选择依据 VideoToolbox 和媒体元数据 | 真机能力探测、首中尾出画、字幕/弹幕/seek/全屏组合；不能以分辨率标签或模拟器画面替代验证 |
| BAS 与人物防挡 | 大量 AppKit 绘制，Vision 绑定桌面视频视图 | 同内容参考图对比，坐标和文字描边测试；热/能耗测试，默认人物防挡关闭 |
| 账号写接口 | 包含扣币、发布、评论、私信和举报 | 测试默认使用 mock；真实写入需明确测试账号和对应操作授权，不能靠批量试发验证 |
| 接口风控/权限 | 源码已有 412、登录失效和验证处理 | 保留原生错误与官方验证入口；无法读取不显示伪数据，不承诺所有账号/网络组合 |
| 已记录的弹幕下载失败 | 历史记录的界面提示为“视频已保存，弹幕下载失败，可单独重试”；尚无本次验证 | 仅作为回归项与状态设计约束；本次没有复现、排查或修复该问题。媒体和弹幕结果分开验收 |

Apple 的正式 PiP 入口是 [AVPlayerViewController](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-standard-player) 或[自定义播放器 PiP](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player)，后者支持 AVPlayerLayer / AVSampleBufferDisplayLayer。上述自绘叠层限制和合成工作量是基于当前源码结构的工程判断，不是已有 iOS 测试结论。

AirPlay 远端播放、Share Extension、桌面小组件、APNs 推送、原生番剧/直播、创作者上传及购买不是当前客户端已实现的原生功能，不自动加入功能对等范围。尤其 127.0.0.1 媒体地址不能直接供远端设备访问；不能因为配置名含 AirPlay 就宣布投屏已经支持。如需扩展，应单独设计和验收。

## 7. 建设顺序与阶段出口

阶段用于控制依赖和验证顺序，最终仍覆盖第3节全部条目。先形成可安装、可播放的最小纵向链路，再完成全部页面和复杂写操作；不能以第一阶段可播放作为最终交付。

| 阶段 | 工作与范围 | 出口条件 |
| --- | --- | --- |
| M0：基线与可行性 | 固定工作区差异清单；新增 iOS 工程与最小共享包；验证登录、DASH/HLS、前后台、PiP、后台下载原型 | 模拟器可构建；至少一部真机完成登录→搜索→播放→seek→清晰度切换→PiP 恢复；后台传输限制有实测记录；关键失败先解决 |
| M1：共享核心与系统壳 | API/认证/业务模型/传输抽库、Keychain、Router、主题、五 Tab、iPad 自适应、文件与图像适配 | Mac 回归通过；iOS 无 AppKit 依赖；账号切换、取消与持久化正确；A01–A03 基础闭环 |
| M2：浏览、搜索、个人中心 | A04–A08、F05–F10、G07–G10；各列表空态、分页与设置全项 | 每个现有 Destination 都有入口与目标 UI；手机和平板无固定宽度溢出；列表状态可恢复 |
| M3：完整播放器 | B01–B13、C01–C04、C08；全屏/迷你/PiP、字幕、预览、队列、诊断 | 真机持续播放、切换、横竖屏、弱网、锁屏、来电与恢复；BAS 同内容对照；不丢播放状态 |
| M4：互动、评论、弹幕管理 | C05–C07、D01–D10；选图、图库、验证与提交结果 | 所有面板与写状态可测试；失败保留草稿；投币与三连不自动重试；真实写入另记授权与结果 |
| M5：资料库与离线 | F01–F04、G01–G06；后台执行器、续传、合轨、导出、离线弹幕 | 暂停/重启/续传/地址过期/同名保护/低空间闭环；断网离线出画；“视频完成但弹幕失败”状态独立 |
| M6：动态与消息 | E01–E07；发布、转发、会话滚动、撤回、通知跳转 | 会话切换/分页/键盘/图片无跳动与串草稿；请求不确定不重发；动态与私信真实写入单独记录 |
| M7：全量验收与安装包 | 全部编号逐项核对、性能/无障碍、资源许可、签名、归档与安装 | Debug/Release 真机通过；覆盖表无无解释漏项；归档与安装验证；所有限制在 QA 明示 |

排期应在 M0 之后按实际 iOS 编译错误、媒体链路和登录结果细化。当前不把未验证工作换成确定工期。M0 和 M1 可以先建立工程，但播放器路线未通过前，不宜投入全部页面精修。

## 8. 验收与测试矩阵

### 自动化

- 保留应用与 Vendor 两套 macOS 测试；抽库后共享业务测试应能由 iOS test target 执行，不通过 macOS executable 间接获得平台依赖。
- 迁移现有回归点：CDN/并发/Range、下载分块与发布事务、缓存清理、账号历史、播放进度、评论合并/富文本/视频链接、弹幕普通与特殊渲染、分页、迷你会话、进度预览。
- 新增 iOS 特有的状态机和集成测试：Scene 转换、音频中断、全屏/迷你/PiP 恢复、后台 session 重新挂接、文件权限失效、键盘避让与导航恢复。
- UI 冒烟覆盖五 Tab、所有二级入口、登录/未登录、主要表单及错误/空态。网络层用可控 fixtures/mock 验证过期响应和不确定写结果，素材不包含凭据、私信或用户媒体。

### 真机

| 维度 | 最低覆盖 |
| --- | --- |
| 设备与布局 | 至少一部较旧受支持 iPhone、一部当前高性能 iPhone、一部 iPad；横竖屏、分屏/窄窗口、安全区域、大字体 |
| 账号 | 游客、普通账号；高画质会员权益在可用账号上单列；失效登录、退出、重新登录和切换账号 |
| 视频 | AVC/HEVC/设备可用的 AV1；单 P/多 P/合集/竖屏/长视频；HDR/杜比和8K分别记录，不以普通 HEVC 成功替代 |
| 播放 | 起播、首中尾seek、连续切清晰度、倍速及松手恢复、暂停/续播、切 Tab 迷你、全屏往返、PiP 停止恢复、字幕与章节 |
| 弹幕 | 普通/反向/顶/底、mode7、BAS路径和变换；暂停/回拖、字号/区域、过滤/云规则、历史、人物防挡、离线 sidecar |
| 网络与生命周期 | Wi-Fi/蜂窝切换、弱网、断网、CDN失败、后台/锁屏、来电/耳机/蓝牙、系统终止与用户强制退出分别验证 |
| 下载 | 前台/后台、暂停继续、重启、地址过期、残块、同名不同内容、合轨中断、外部导出、权限失效、磁盘不足 |
| 社区 | 评论楼中楼、图文/表情、动态、私信历史锚点、两分钟撤回、系统通知、验证返回；真实写操作有独立授权与结果记录 |
| 性能与无障碍 | 首帧与缓冲、CPU/GPU/内存、热与耗电、60/120Hz；VoiceOver、减少动态效果、降低透明度、深浅/自定义背景对比度 |

验收证据至少区分：构建通过、播放器 ready、实际音画出画、交互通过、服务器确认、下载文件校验、安装包安装通过。每条功能的记录应包含“已实现 / 自动测试 / 真机验证 / 接口或设备限制”，不以一张截图或一次联网成功覆盖全部状态。

最终功能核对表以 A01–G10 共 66 条为基础；每条都要有实现落点和验证结论。平台无法等价的行为必须写明替代设计，不能静默删除。

## 9. 构建、资源与交付

工程目标：单独的 iOS/iPadOS bundle identifier、应用图标 Asset Catalog、Launch Screen 配置、必要的后台能力、隐私声明与用途说明、Debug/Release 配置、共享 scheme。证书与签名由真实开发者团队配置，不使用 Mac 的 `.app` 签名流程冒充 iOS 签名。

新增 `Scripts/build-ios.sh` 与对应 QA 说明，流程至少包含：

1. `xcodebuild` 构建 iOS Simulator，执行共享与 iOS 集成测试。
2. 对连接的 iPhone/iPad 构建并安装，完成真实渲染与交互检查。
3. 用正确团队签名执行 Release Archive，检查资源、版本、许可和 entitlements。
4. 按实际授权的开发/Ad Hoc/TestFlight 分发方式导出；验证安装后的播放、重启、Keychain 与下载恢复。

本计划不包含自动上传 TestFlight、App Store 送审或公开发布。若选择商店分发，需独立核对当时的审核与服务授权要求；本次未做上架资格评估。

最终交付应包含 iOS/iPadOS 工程、共享组件、完整覆盖表、设计/布局说明、构建脚本、测试及真机 QA 记录、可安装的签名产物或明确的签名阻碍。只交模拟器构建不算完成“iOS App”。

## 10. 源文件迁移索引

以下覆盖审阅时应用目录的全部 62 个 Swift 文件；文件分组用于后续落实负责人和改动范围，不表示代码已搬迁。

| 模块 | 当前应用文件 | 迁移处理 |
| --- | --- | --- |
| 启动与状态 | `BiliGlassApp.swift`、`Store.swift`、`InitialWindowFocus.swift` | 拆分业务/导航；iOS 重写 App/焦点生命周期，Mac 初始窗口焦点留在 Mac |
| 浏览与通用 UI | `Views.swift`、`Regions.swift`、`SearchFeatures.swift`、`LoadMoreFooter.swift` | 共享模型和通用卡片；重做手机导航、布局与搜索面板 |
| 主题与设置 | `GlassStyle.swift`、`Preferences.swift` | 共享主题/偏好；存储路径、背景导入和设置容器平台化 |
| API 与安全 | `API.swift`、`TaskDeadline.swift` | 拆模型、请求、凭据；移除图片/界面耦合，保留超时与会话隔离 |
| 社区与文本 | `Community.swift`、`CommunityViews.swift`、`CommentPage.swift`、`CommentText.swift`、`CommentVideoLink.swift`、`EmojiPicker.swift` | 共享模型/提交/分页；富文本与表单适配 UIKit/SwiftUI |
| 图片 | `ImageGallery.swift`、`ImageUpload.swift`、`ThumbnailCache.swift` | 共享下载/验证/解码；图库、选图、保存平台化 |
| 视频互动 | `VideoActions.swift`、`VideoActionViews.swift` | 共享业务状态；所有确认、收藏、分享、验证面板移动化 |
| 个人空间与动态 | `NativeSpace.swift`、`DynamicPublishing.swift`、`ContentModeration.swift` | 共享数据与写入；手机详情/编辑/举报/黑名单页面 |
| 消息 | `Messaging.swift`、`InboxViews.swift`、`ConversationTimeline.swift`、`MessageShare.swift` | 共享会话状态与解析；列表/详情、锚点、选图、复制平台化 |
| 历史 | `AccountHistory.swift`、`WatchHistorySync.swift`、`AppDateFormat.swift`、`PlaybackProgressDeadline.swift` | 共享合并/同步/格式；UI 与 Scene 提交适配 |
| 资料库管理 | `LibraryManagement.swift` | 共享收藏夹/稍后再看操作；手机编辑页、多选、批量结果和删除确认 |
| 播放会话 | `Player.swift`、`FullscreenPlayer.swift`、`MiniPlayer.swift`、`PlayerKeyboard.swift` | 拆 AVPlayer 会话与 Mac 表面；新增 iOS 全屏/PiP/手势/键盘适配 |
| 播放页附加能力 | `PlayerControls.swift`、`PlaybackDetails.swift`、`VideoExtras.swift`、`VideoPreview.swift` | 共享状态/裁剪；触控控制、诊断、字幕和队列 UI 重排 |
| 媒体传输 | `CDNSelection.swift`、`ParallelVideoStream.swift`、`PlaybackDiskCache.swift`、`VideoSignalling.swift` | 共享网络/媒体语义；沙盒、后台、内存与移动数据策略适配 |
| 弹幕 | `Danmaku.swift`、`DanmakuTextBitmap.swift`、`SpecialDanmaku.swift`、`BAS.swift`、`SVGPath.swift`、`DanmakuSettings.swift`、`DanmakuManagement.swift`、`PersonAvoidance.swift` | 解析/几何/业务共享；AppKit绘制、刷新和遮罩承载改为 iOS 实现 |
| 下载与媒体文件 | `Downloads.swift`、`DownloadsView.swift`、`DownloadPiece.swift`、`DownloadPublication.swift`、`NativeComposition.swift`、`MP4Compatibility.swift` | 共享状态/校验/合轨；增加后台执行器、文档导出与沙盒恢复 |
| 官方 Web 与诊断 | `WebPanel.swift`、`Diagnostics.swift` | 保留官方验证业务；UIKit WebKit 代理与真机诊断重写 |

Vendor 模块整体另行通过 iOS 编译与测试确认，保留 MIT 许可和本地修改说明。当前没有引入新的第三方依赖。
