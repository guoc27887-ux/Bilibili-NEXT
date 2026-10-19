import BiliApplication
import BiliModels
import Foundation

/// 字幕目录不可用：轨道 ID 重复或显示名为空；bridge 收到后按无字幕起播。
enum NativeSubtitleSourceError: Error, Sendable, Equatable {
    case duplicateTrackID
    case emptyDisplayLabel
}

/// 字幕目录的一项：轨道 ID、显示名、BCP 47 语言标签（无法识别时为 `und`）与 HLS 特征。
struct NativeSubtitleCatalogEntry: Sendable, Equatable {
    let trackID: String
    let label: String
    let languageTag: String
    let characteristics: [String]
}

/// 只属于一次 playback identity 的字幕来源；route 被停止后不再持有。
struct NativeSubtitleSource: Sendable {
    let useCase: SubtitleUseCase
    let identity: PlaybackItemIdentity

    func catalog() async throws -> [NativeSubtitleCatalogEntry] {
        let tracks = try await useCase.tracks(for: identity)
        let options = SubtitleDisplayPolicy.options(for: tracks)
        var trackIDs = Set<String>()
        return try zip(tracks, options).map { track, option in
            guard trackIDs.insert(option.trackID).inserted else {
                throw NativeSubtitleSourceError.duplicateTrackID
            }
            guard !option.label.isEmpty else {
                throw NativeSubtitleSourceError.emptyDisplayLabel
            }
            return NativeSubtitleCatalogEntry(
                trackID: option.trackID,
                label: option.label,
                languageTag: Self.languageTag(for: track),
                characteristics: Self.characteristics(for: track.kind)
            )
        }
    }

    func cues(for trackID: String) async throws -> [SubtitleCue] {
        try await useCase.cues(for: trackID, identity: identity)
    }

    /// 规范化为 BCP 47 形状（自动字幕去掉 `ai-` 前缀），不合规时为 `und`；playlist 只写这个规范值。
    private static func languageTag(for track: SubtitleTrack) -> String {
        var source = track.languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if track.kind == .automatic, source.hasPrefix("ai-") {
            source.removeFirst(3)
        }
        let subtags = source.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard let primary = subtags.first,
            (2...3).contains(primary.count),
            primary.allSatisfy(\.isASCIILetter),
            subtags.dropFirst().allSatisfy({ subtag in
                (1...8).contains(subtag.count)
                    && subtag.allSatisfy(\.isASCIIAlphaNumeric)
            })
        else {
            return "und"
        }
        return subtags.joined(separator: "-")
    }

    private static func characteristics(
        for kind: SubtitleTrackKind
    ) -> [String] {
        switch kind {
        case .standard:
            []
        case .automatic:
            ["public.machine-generated"]
        case .unknown:
            []
        }
    }
}

extension Character {
    fileprivate var isASCIILetter: Bool {
        isASCII && isLetter
    }

    fileprivate var isASCIIAlphaNumeric: Bool {
        isASCII && (isLetter || isNumber)
    }
}
