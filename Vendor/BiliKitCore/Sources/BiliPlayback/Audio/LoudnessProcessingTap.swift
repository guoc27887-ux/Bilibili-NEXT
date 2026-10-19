@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaToolbox
import Synchronization

/// 挂在 AVPlayerItem 全部音轨混音上的增益 tap。
///
/// macOS 27 起官方支持对 HLS 混音挂 tap；混音 tap 必须用指定处理格式创建，否则格式未定义。
/// 处理格式固定为 `State.prepare` 接受的 32 位浮点非交错立体声，系统负责前后的格式转换。
///
/// 由 `LoudnessNormalizationController` 创建并持有，经 `makeAudioMix` 挂到 item 上。
/// `@unchecked Sendable` 的依据是只有不可变的 `let`：`tap` 创建后只交给 audio mix，
/// 跨线程的写入只有 `setTargetGain`，经 `State` 的原子值完成。
final class LoudnessProcessingTap: @unchecked Sendable {
    /// 目标增益变化时逐帧线性过渡的时长，避免切换音轨时增益突变；调长过渡更慢，调短更接近突变。
    static let rampDurationSeconds = 0.150
    /// 处理格式为 48 kHz 立体声：B 站 AAC 音轨均为立体声，多数为 44.1 kHz，由系统重采样（见
    /// docs/ARCHITECTURE.md「响度均一化（macOS 27 起）」）。
    static let processingSampleRate = 48_000.0
    static let processingChannelCount: UInt32 = 2

    private let state: State
    private let tap: MTAudioProcessingTap

    private init(state: State, tap: MTAudioProcessingTap) {
        self.state = state
        self.tap = tap
    }

    @available(macOS 27.0, *)
    static func make(initialGain: Float) -> LoudnessProcessingTap? {
        guard initialGain.isFinite, initialGain > 0,
            let processingFormat = processingFormat()
        else { return nil }
        let state = State(initialGain: initialGain)
        // tap storage 持有 State 的一个引用，由 finalize 回调释放；创建失败时没有 tap 可 finalize，
        // 由下面的失败分支释放。
        let retainedState = Unmanaged.passRetained(state)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedState.toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)
                ).release()
            },
            prepare: { tap, _, format in
                LoudnessProcessingTap.state(for: tap).prepare(format.pointee)
            },
            unprepare: { tap in
                LoudnessProcessingTap.state(for: tap).unprepare()
            },
            process: process
        )
        var createdTap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreateWithPreferredFormat(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            processingFormat,
            &createdTap
        )
        guard status == noErr, let createdTap else {
            retainedState.release()
            return nil
        }
        return LoudnessProcessingTap(state: state, tap: createdTap)
    }

    @available(macOS 27.0, *)
    func makeAudioMix() -> AVAudioMix {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = AVAudioMixInputParametersTrackID.mixID.rawValue
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    func setTargetGain(_ gain: Float) {
        state.setTargetGain(gain)
    }

    private static func processingFormat() -> CMAudioFormatDescription? {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        var description = AudioStreamBasicDescription(
            mSampleRate: processingSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample,
            mChannelsPerFrame: processingChannelCount,
            mBitsPerChannel: bytesPerSample * 8,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }
}

extension LoudnessProcessingTap {
    /// tap 回调使用的增益状态：原子的目标增益，以及只属于处理回调的格式与逐帧过渡进度。
    ///
    /// `@unchecked Sendable`：跨线程的只有 `targetGainBits`（增益的位模式，`setTargetGain` 以
    /// releasing 写入、处理回调以 acquiring 读取）；其余 `var` 只在 prepare、process、unprepare
    /// 回调里读写，这些回调由 MediaToolbox 依次调用、彼此不并发，安全靠这一点而不是锁。process
    /// 在实时音频线程运行，只读写这些固定字段与原子值，不分配、不加锁、不记日志（见
    /// docs/ARCHITECTURE.md「响度均一化（macOS 27 起）」）。
    final class State: @unchecked Sendable {
        private let targetGainBits: Atomic<UInt32>
        private var formatIsSupported = false
        private var sampleRate = 0.0
        private var currentGain: Float
        private var rampStartGain: Float
        private var rampTargetGain: Float
        private var rampFrameCount = 0
        private var rampFrameIndex = 0

        init(initialGain: Float) {
            targetGainBits = Atomic(initialGain.bitPattern)
            currentGain = initialGain
            rampStartGain = initialGain
            rampTargetGain = initialGain
        }

        func setTargetGain(_ gain: Float) {
            guard gain.isFinite, gain > 0 else { return }
            targetGainBits.store(gain.bitPattern, ordering: .releasing)
        }

        /// 核对系统给出的处理格式并把增益直接置为目标值；不是 32 位小端 packed 浮点线性 PCM 时，
        /// process 原样直通。
        func prepare(_ format: AudioStreamBasicDescription) {
            sampleRate = format.mSampleRate
            let flags = format.mFormatFlags
            let isFloat = flags & kAudioFormatFlagIsFloat != 0
            let isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
            let isPacked = flags & kAudioFormatFlagIsPacked != 0
            let isNonInterleaved =
                flags & kAudioFormatFlagIsNonInterleaved != 0
            let expectedBytesPerFrame =
                UInt32(MemoryLayout<Float>.size)
                * (isNonInterleaved ? 1 : format.mChannelsPerFrame)
            formatIsSupported =
                format.mFormatID == kAudioFormatLinearPCM
                && isFloat
                && !isBigEndian
                && isPacked
                && format.mBitsPerChannel == 32
                && format.mChannelsPerFrame > 0
                && format.mFramesPerPacket == 1
                && format.mBytesPerFrame == expectedBytesPerFrame
                && format.mBytesPerPacket == expectedBytesPerFrame
                && sampleRate.isFinite
                && sampleRate > 0
            resetToTarget()
        }

        func unprepare() {
            formatIsSupported = false
            sampleRate = 0
            resetToTarget()
        }

        func resetToTarget() {
            let target = targetGain()
            currentGain = target
            rampStartGain = target
            rampTargetGain = target
            rampFrameCount = 0
            rampFrameIndex = 0
        }

        /// 原地给每帧的每个声道乘当前增益。
        ///
        /// 流起点（`discontinuity`）直接跳到目标增益，不做过渡；
        /// 目标变化时从当前增益开始一次新的线性过渡。
        func process(
            buffers: UnsafeMutablePointer<AudioBufferList>,
            frameCount: Int,
            discontinuity: Bool
        ) {
            guard formatIsSupported, frameCount > 0 else { return }
            if discontinuity { resetToTarget() }

            let target = targetGain()
            if target != rampTargetGain {
                rampStartGain = currentGain
                rampTargetGain = target
                rampFrameCount = max(
                    1,
                    Int(
                        (sampleRate * LoudnessProcessingTap.rampDurationSeconds)
                            .rounded()
                    )
                )
                rampFrameIndex = 0
            }

            let bufferList = UnsafeMutableAudioBufferListPointer(buffers)
            for frame in 0..<frameCount {
                let gain = gainForCurrentFrame()
                for bufferIndex in bufferList.indices {
                    let buffer = bufferList[bufferIndex]
                    let channels = Int(buffer.mNumberChannels)
                    guard channels > 0, let data = buffer.mData else { continue }
                    let availableSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let firstSample = frame * channels
                    guard firstSample >= 0,
                        firstSample < availableSamples,
                        channels <= availableSamples - firstSample
                    else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for channel in 0..<channels {
                        samples[firstSample + channel] *= gain
                    }
                }
                advanceRamp(appliedGain: gain)
            }
        }

        private func targetGain() -> Float {
            Float(
                bitPattern: targetGainBits.load(ordering: .acquiring)
            )
        }

        private func gainForCurrentFrame() -> Float {
            guard rampFrameCount > 0, rampFrameIndex < rampFrameCount else {
                return rampTargetGain
            }
            let progress = Float(rampFrameIndex + 1) / Float(rampFrameCount)
            return rampStartGain + (rampTargetGain - rampStartGain) * progress
        }

        private func advanceRamp(appliedGain: Float) {
            currentGain = appliedGain
            guard rampFrameCount > 0 else {
                return
            }
            rampFrameIndex += 1
            if rampFrameIndex >= rampFrameCount {
                currentGain = rampTargetGain
                rampFrameCount = 0
                rampFrameIndex = 0
            }
        }
    }

    /// 从 tap storage 取回 State，不改变引用计数；只在 finalize 之前的 tap 回调里调用。
    static func state(for tap: MTAudioProcessingTap) -> State {
        Unmanaged<State>.fromOpaque(
            MTAudioProcessingTapGetStorage(tap)
        ).takeUnretainedValue()
    }

    /// 实时处理回调：先取源音频，再交给 `State.process` 原地改写；取源失败或没有帧时不处理。
    static let process: MTAudioProcessingTapProcessCallback = {
        tap,
        requestedFrames,
        _,
        buffers,
        framesOut,
        flagsOut in
        var sourceFlags = MTAudioProcessingTapFlags()
        var sourceFrames = CMItemCount(0)
        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            requestedFrames,
            buffers,
            &sourceFlags,
            nil,
            &sourceFrames
        )
        framesOut.pointee = sourceFrames
        flagsOut.pointee = sourceFlags
        guard status == noErr, sourceFrames > 0 else { return }
        state(for: tap).process(
            buffers: buffers,
            frameCount: Int(sourceFrames),
            discontinuity:
                sourceFlags & kMTAudioProcessingTapFlag_StartOfStream != 0
        )
    }
}
