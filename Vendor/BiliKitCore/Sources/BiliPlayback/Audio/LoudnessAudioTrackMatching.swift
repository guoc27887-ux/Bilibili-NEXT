@preconcurrency import AVFoundation
import BiliModels
import Foundation

extension PlaybackAudioTrack.Role {
    /// 写进 HLS `CHARACTERISTICS` 的音轨角色；播放列表与按选项找回音轨共用这一映射。
    var hlsCharacteristic: String {
        switch self {
        case .original: "public.original-content"
        case .machineGenerated: "public.machine-generated"
        }
    }
}

/// 系统选中的音轨选项对应哪一条音轨：只看语言与角色。
///
/// `displayName` 是系统本地化后的界面名称（macOS 27 会加上语言与“原始”等标注），不能用来匹配；
/// 原声只有一条、机器配音每种语言一条，语言加角色已能唯一确定音轨。
enum LoudnessAudioTrackMatching {
    /// `optionLanguageTag` 是选项保留的原始语言标签（即播放列表的 `LANGUAGE`），没有时用 locale。
    static func matches(
        _ track: PlaybackAudioTrack,
        optionLanguageTag: String?,
        optionHasCharacteristic: (AVMediaCharacteristic) -> Bool
    ) -> Bool {
        sameLanguage(track.languageTag, optionLanguageTag)
            && optionHasCharacteristic(
                AVMediaCharacteristic(rawValue: track.role.hlsCharacteristic)
            )
    }

    /// 缺省视为 `und`；字面不同时按 BCP 47 补全后比较，`zh-Hans` 与 `zh_CN` 之类的写法差异视为同一语言。
    static func sameLanguage(_ expected: String?, _ actual: String?) -> Bool {
        let expected = normalized(expected)
        let actual = normalized(actual)
        if expected == actual { return true }
        guard expected != undetermined, actual != undetermined else { return false }
        return Locale.Language(identifier: expected).maximalIdentifier.lowercased()
            == Locale.Language(identifier: actual).maximalIdentifier.lowercased()
    }

    private static let undetermined = "und"

    private static func normalized(_ tag: String?) -> String {
        guard let tag, !tag.isEmpty else { return undetermined }
        return tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
