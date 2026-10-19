@preconcurrency import AVFoundation
import Foundation

/// 用户上次选中的原生字幕选项（系统属性列表的二进制编码），重新开启字幕时优先恢复同一选项。
struct NativeSubtitleSelectionPreference: Sendable {
    let propertyListData: Data?
}

extension AVPlayerEngine {
    static func subtitlePreference(
        for option: AVMediaSelectionOption
    ) -> NativeSubtitleSelectionPreference {
        NativeSubtitleSelectionPreference(
            propertyListData: try? PropertyListSerialization.data(
                fromPropertyList: option.propertyList(),
                format: .binary,
                options: 0
            )
        )
    }

    static func subtitleOption(
        in group: AVMediaSelectionGroup,
        restoring preference: NativeSubtitleSelectionPreference?
    ) -> AVMediaSelectionOption? {
        let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(
            from: group.options
        )
        guard !playable.isEmpty else { return nil }
        if let preference {
            if let data = preference.propertyListData,
                let propertyList = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ),
                let exact = group.mediaSelectionOption(
                    withPropertyList: propertyList
                ),
                exact.isPlayable
            {
                return exact
            }
        }
        let preferred = AVMediaSelectionGroup.mediaSelectionOptions(
            from: playable,
            filteredAndSortedAccordingToPreferredLanguages:
                Locale.preferredLanguages
        )
        return preferred.first ?? playable.first
    }
}
