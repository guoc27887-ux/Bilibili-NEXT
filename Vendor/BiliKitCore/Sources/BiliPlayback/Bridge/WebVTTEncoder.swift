import BiliModels
import Foundation

/// WebVTT 编码失败：时间基无效、时间戳溢出，或某条 cue 的时间或文本不合规，整份字幕不可用。
public enum WebVTTEncoderError: Error, Sendable, Equatable {
    case invalidTimescale
    case timestampOverflow
    case invalidCue(index: Int)
    case unsafeCueText(index: Int)
}

/// 把已验证 cue 编码为与 DASH presentation timeline 对齐的 WebVTT。
public struct WebVTTEncoder: Sendable {
    /// cue 结束时间上限 24 小时：超出视为数据异常，整份字幕编码失败。
    private static let maximumCueSeconds = 24.0 * 60.0 * 60.0

    public init() {}

    public func encode(
        cues: [SubtitleCue],
        earliestPresentationTime: UInt64,
        timescale: UInt32
    ) throws -> Data {
        let mpegTimestamp = try mpegTimestamp(
            earliestPresentationTime: earliestPresentationTime,
            timescale: timescale
        )
        var lines = [
            "WEBVTT",
            "X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:\(mpegTimestamp)",
            ""
        ]
        var previousStart = 0.0
        for (index, cue) in cues.enumerated() {
            guard cue.startSeconds.isFinite,
                cue.endSeconds.isFinite,
                cue.startSeconds >= 0,
                cue.endSeconds > cue.startSeconds,
                cue.endSeconds <= Self.maximumCueSeconds,
                index == 0 || cue.startSeconds >= previousStart
            else {
                throw WebVTTEncoderError.invalidCue(index: index)
            }
            previousStart = cue.startSeconds
            lines.append(
                "\(timestamp(cue.startSeconds)) --> \(timestamp(cue.endSeconds))"
            )
            lines.append(try safeText(cue.text, index: index))
            lines.append("")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// 把视频 SIDX 起点换算到 90 kHz 的 MPEG-TS 时钟写进 `X-TIMESTAMP-MAP`，
    /// 让 cue 的 0 秒对齐视频时间轴起点。
    private func mpegTimestamp(
        earliestPresentationTime: UInt64,
        timescale: UInt32
    ) throws -> UInt64 {
        guard timescale > 0 else {
            throw WebVTTEncoderError.invalidTimescale
        }
        let divisor = UInt64(timescale)
        let quotient = earliestPresentationTime / divisor
        let remainder = earliestPresentationTime % divisor
        let (whole, wholeOverflow) = quotient.multipliedReportingOverflow(by: 90_000)
        let (fractionProduct, fractionOverflow) = remainder.multipliedReportingOverflow(
            by: 90_000
        )
        guard !wholeOverflow, !fractionOverflow else {
            throw WebVTTEncoderError.timestampOverflow
        }
        let fraction = fractionProduct / divisor
        let (result, resultOverflow) = whole.addingReportingOverflow(fraction)
        guard !resultOverflow else {
            throw WebVTTEncoderError.timestampOverflow
        }
        return result
    }

    private func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int64((seconds * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let wholeSeconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(
            format: "%02lld:%02lld:%02lld.%03lld",
            locale: Locale(identifier: "en_US_POSIX"),
            hours,
            minutes,
            wholeSeconds,
            remainder
        )
    }

    /// 拒绝除换行与 Tab 外的控制字符，并转义 `&`、`<`、`>`，正文不会被当作 WebVTT 标签。
    ///
    /// 空行换成一个空格：WebVTT 里空行会结束 cue。
    private func safeText(_ rawValue: String, index: Int) throws -> String {
        let normalized =
            rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard
            !normalized.unicodeScalars.contains(where: { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    && scalar.value != 0x0A
                    && scalar.value != 0x09
            })
        else {
            throw WebVTTEncoderError.unsafeCueText(index: index)
        }
        return
            normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let escaped =
                    line
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return escaped.isEmpty ? " " : escaped
            }
            .joined(separator: "\n")
    }
}
