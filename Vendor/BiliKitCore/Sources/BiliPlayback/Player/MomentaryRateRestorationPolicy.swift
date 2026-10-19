@preconcurrency import AVFoundation

/// 按住期间的临时倍速结束时，对播放速率采取的恢复动作。
enum MomentaryRateRestorationAction: Equatable {
    case none
    case setCurrentRate
    case resumeAtDefaultRate
}

/// 临时倍速结束时的恢复策略：只在播放器仍处于临时倍速时改回默认速率。
///
/// 暂停时不动；仍按临时倍速播放时改回默认速率；等待播放时速率已归零或仍是临时倍速则按默认
/// 速率继续。速率已被其他操作改过时保持不变，临时倍速不能覆盖用户随后的选择。
enum MomentaryRateRestorationPolicy {
    static func action(
        timeControlStatus: AVPlayer.TimeControlStatus,
        currentRate: Float,
        momentaryRate: Float
    ) -> MomentaryRateRestorationAction {
        let stillUsesMomentaryRate =
            abs(currentRate - momentaryRate) < 0.01
        switch timeControlStatus {
        case .paused:
            return .none
        case .playing:
            return stillUsesMomentaryRate ? .setCurrentRate : .none
        case .waitingToPlayAtSpecifiedRate:
            return currentRate == 0 || stillUsesMomentaryRate
                ? .resumeAtDefaultRate : .none
        @unknown default:
            return .none
        }
    }
}
