/// 字幕轨的来源：`automatic` 为 AI 生成，`standard` 为人工中文字幕，字段组合无法确定时为
/// `unknown`。
public enum SubtitleTrackKind: Sendable, Equatable {
    case standard
    case automatic
    case unknown
}

/// 字幕目录（`/x/player/wbi/v2`）里的一条字幕轨，供界面选择；不携带正文地址。
///
/// 正文地址映射时已过 `SubtitleURLPolicy`，只留在 BiliAPI 的字幕仓库里按 `id` 取用，取用前再查一次
/// （见 SECURITY-MODEL §4）。
public struct SubtitleTrack: Sendable, Equatable, Identifiable {
    public let id: String
    public let languageCode: String
    public let displayName: String
    public let kind: SubtitleTrackKind

    public init(
        id: String,
        languageCode: String,
        displayName: String,
        kind: SubtitleTrackKind
    ) {
        self.id = id
        self.languageCode = languageCode
        self.displayName = displayName
        self.kind = kind
    }
}

/// 一条字幕：半开区间 `[startSeconds, endSeconds)` 与去掉首尾空白的正文。
///
/// 解码时拒绝非有限、负数或超过 24 小时的时间与空正文，整份字幕按开始时间非递减。
public struct SubtitleCue: Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }

    public func contains(positionSeconds: Double) -> Bool {
        startSeconds <= positionSeconds && positionSeconds < endSeconds
    }
}
