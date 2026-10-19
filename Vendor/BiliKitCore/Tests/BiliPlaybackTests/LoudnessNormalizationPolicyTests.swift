@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Testing

@testable import BiliModels
@testable import BiliPlayback

struct LoudnessNormalizationPolicyTests {
    private let policy = LoudnessNormalizationPolicy()

    @Test
    func louderThanTargetIsTurnedDownToMinus18LUFS() {
        let gain = policy.linearGain(
            for: metadata(measuredI: -10, measuredTP: 1)
        )

        #expect(abs(gain - Float(pow(10, -8.0 / 20))) < 0.0001)
    }

    /// 只压低不放大：即使峰值余量充足，安静的音轨也保持原样。
    @Test(arguments: [-18.0, -25.0, -40.0])
    func targetOrQuieterKeepsOriginalLoudness(measuredI: Double) {
        #expect(policy.linearGain(for: metadata(measuredI: measuredI, measuredTP: -20)) == 1)
    }

    @Test
    func attenuationCapAndInvalidMetadataFallBackSafely() {
        let attenuated = policy.linearGain(
            for: metadata(measuredI: -1, measuredTP: -20)
        )
        let invalid = PlaybackLoudnessMetadata(
            measuredIntegratedLUFS: .nan,
            measuredLoudnessRangeLU: 3,
            measuredTruePeakDBTP: -2,
            measuredThresholdLUFS: -30,
            targetIntegratedLUFS: -14,
            targetTruePeakDBTP: -1
        )

        #expect(abs(attenuated - Float(pow(10, -12.0 / 20))) < 0.0001)
        #expect(policy.linearGain(for: invalid) == 1)
        #expect(policy.linearGain(for: nil) == 1)
    }

    @Test
    func float32ProcessorHandlesInterleavedAndBoundedBuffers() {
        let state = LoudnessProcessingTap.State(initialGain: 2)
        state.prepare(floatFormat(sampleRate: 10, channels: 2, interleaved: true))
        var samples: [Float] = [1, -1, 0.5, -0.5, 7]
        samples.withUnsafeMutableBytes { bytes in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: 4 * UInt32(MemoryLayout<Float>.size),
                    mData: bytes.baseAddress
                )
            )
            state.process(buffers: &bufferList, frameCount: 3, discontinuity: false)
        }

        #expect(samples == [2, -2, 1, -1, 7])
    }

    @Test
    func float32ProcessorHandlesNonInterleavedRampAndUnsupportedFormat() {
        let state = LoudnessProcessingTap.State(initialGain: 1)
        state.prepare(floatFormat(sampleRate: 10, channels: 2, interleaved: false))
        state.setTargetGain(2)
        var left: [Float] = [1, 1]
        var right: [Float] = [1, 1]
        withUnsafeMutablePointer(to: &left) { leftArray in
            withUnsafeMutablePointer(to: &right) { rightArray in
                leftArray.pointee.withUnsafeMutableBytes { leftBytes in
                    rightArray.pointee.withUnsafeMutableBytes { rightBytes in
                        let size =
                            MemoryLayout<AudioBufferList>.size
                            + MemoryLayout<AudioBuffer>.size
                        let storage = UnsafeMutableRawPointer.allocate(
                            byteCount: size,
                            alignment: MemoryLayout<AudioBufferList>.alignment
                        )
                        defer { storage.deallocate() }
                        let list = storage.assumingMemoryBound(
                            to: AudioBufferList.self
                        )
                        list.pointee.mNumberBuffers = 2
                        let buffers = UnsafeMutableAudioBufferListPointer(list)
                        buffers[0] = AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(leftBytes.count),
                            mData: leftBytes.baseAddress
                        )
                        buffers[1] = AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(rightBytes.count),
                            mData: rightBytes.baseAddress
                        )
                        state.process(
                            buffers: list,
                            frameCount: 2,
                            discontinuity: false
                        )
                    }
                }
            }
        }
        #expect(abs(left[0] - 1.5) < 0.001)
        #expect(left == right)

        let unsupported = LoudnessProcessingTap.State(initialGain: 2)
        var format = floatFormat(sampleRate: 10, channels: 1, interleaved: true)
        format.mBitsPerChannel = 16
        unsupported.prepare(format)
        var untouched: [Float] = [1]
        untouched.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            unsupported.process(buffers: &list, frameCount: 1, discontinuity: false)
        }
        #expect(untouched == [1])
    }

    @Test
    func discontinuityResetsAnInFlightRampToTheLatestTarget() {
        let state = LoudnessProcessingTap.State(initialGain: 1)
        state.prepare(floatFormat(sampleRate: 48_000, channels: 1, interleaved: true))
        state.setTargetGain(2)
        var samples: [Float] = [1]
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            state.process(buffers: &list, frameCount: 1, discontinuity: true)
        }

        #expect(samples == [2])
    }

    /// 只有至少一条音轨需要压低时才安装 tap；全都不比目标响（或没有响度数据）时不装。
    @Test
    func tapIsInstalledOnlyWhenSomeTrackNeedsAttenuation() {
        let quiet = audioTrack(role: .original, metadata: metadata(measuredI: -25, measuredTP: -3))
        let loud = audioTrack(
            role: .machineGenerated,
            languageTag: "en",
            metadata: metadata(measuredI: -10, measuredTP: 1)
        )
        let unmeasured = audioTrack(role: .original, metadata: nil)

        #expect(!policy.needsAttenuation([quiet, unmeasured]))
        #expect(policy.needsAttenuation([quiet, loud]))
        #expect(!policy.needsAttenuation([]))
    }

    /// 语言按 BCP 47 补全后比较：同一语言的不同写法能对上，不同语言或文字不能。
    @Test(
        arguments: [
            (nil, "und", true),
            ("und", nil, true),
            ("zh-Hans", "zh-Hans", true),
            ("zh-Hans", "zh_CN", true),
            ("zh-Hans", "zh-Hans-CN", true),
            ("zh-Hant", "zh-TW", true),
            ("en", "en-US", true),
            ("ja", "JA", true),
            ("zh-Hans", "zh-Hant", false),
            ("en", "ja", false),
            ("en", "und", false),
            (nil, "en", false)
        ] as [(String?, String?, Bool)]
    )
    func audioTrackLanguagesMatchAcrossTagSpellings(
        expected: String?,
        actual: String?,
        matches: Bool
    ) {
        #expect(LoudnessAudioTrackMatching.sameLanguage(expected, actual) == matches)
    }

    /// 选项按语言与角色找回音轨，与显示名无关；角色不同的同语言选项对不上。
    @Test
    func audioTrackMatchingUsesLanguageAndRoleOnly() {
        let original = audioTrack(role: .original, metadata: nil)
        let dub = audioTrack(role: .machineGenerated, languageTag: "zh-Hans", metadata: nil)
        func characteristics(
            _ values: Set<String>
        ) -> (AVMediaCharacteristic) -> Bool {
            { values.contains($0.rawValue) }
        }

        #expect(
            LoudnessAudioTrackMatching.matches(
                original,
                optionLanguageTag: "und",
                optionHasCharacteristic: characteristics(["public.original-content"])
            )
        )
        #expect(
            LoudnessAudioTrackMatching.matches(
                dub,
                optionLanguageTag: "zh_CN",
                optionHasCharacteristic: characteristics(["public.machine-generated"])
            )
        )
        #expect(
            !LoudnessAudioTrackMatching.matches(
                dub,
                optionLanguageTag: "zh-Hans",
                optionHasCharacteristic: characteristics(["public.original-content"])
            )
        )
    }

    private func audioTrack(
        role: PlaybackAudioTrack.Role,
        languageTag: String? = nil,
        metadata: PlaybackLoudnessMetadata?
    ) -> PlaybackAudioTrack {
        PlaybackAudioTrack(
            id: "\(role)-\(languageTag ?? "und")",
            displayName: "系统本地化后的名称",
            languageTag: languageTag,
            role: role,
            isDefault: role == .original,
            isAutoselect: role == .original,
            loudnessMetadata: metadata,
            representations: []
        )
    }

    private func metadata(
        measuredI: Double,
        measuredTP: Double
    ) -> PlaybackLoudnessMetadata {
        PlaybackLoudnessMetadata(
            measuredIntegratedLUFS: measuredI,
            measuredLoudnessRangeLU: 3,
            measuredTruePeakDBTP: measuredTP,
            measuredThresholdLUFS: min(measuredI - 10, -10),
            targetIntegratedLUFS: -14,
            targetTruePeakDBTP: -1
        )
    }

    private func floatFormat(
        sampleRate: Double,
        channels: UInt32,
        interleaved: Bool
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags:
                kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: 4 * (interleaved ? channels : 1),
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * (interleaved ? channels : 1),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
