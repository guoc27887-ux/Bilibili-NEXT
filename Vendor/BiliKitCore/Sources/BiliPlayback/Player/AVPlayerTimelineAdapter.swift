@preconcurrency import AVFoundation
import BiliApplication
import Foundation
import os

/// 把 AVPlayer/KVO/notification 事件投影为平台无关、identity-safe 的播放时间线。
///
/// 所有 callback 都同时核对当前 `AVPlayerItem` 与 item token；observer bag 在替换、失败和
/// clear 时统一释放，避免旧 item 继续推进弹幕、观看进度等时间线消费方。
@MainActor
final class AVPlayerTimelineAdapter {
    /// 已发出、尚未收尾的 seek：目标位置，以及是否已观察到落在目标附近的系统 time-jump。
    ///
    /// 已观察到时，收尾不再登记落点；未观察到就被新 seek 取代时，目标转入过期落点，
    /// 迟到的跳变据此被吞掉。
    private struct PendingSeek {
        let operationID: UUID
        let targetSeconds: Double
        var observedLanding = false
    }

    /// 一次 seek 的落点，用来辨认迟到的系统 time-jump。
    private struct SeekLanding {
        let operationID: UUID
        let positionSeconds: Double
    }

    /// 按住期间的临时倍速；只有同一 ID、同一 item 时 `endMomentaryRate` 才恢复速率。
    private struct MomentaryRateSession {
        let id: UUID
        let item: AVPlayerItem
        let rate: Float
    }

    var onFailed: (@MainActor () -> Void)?
    var onSeekSupersededByExternalJump: (@MainActor (UUID) -> Void)?

    var currentSnapshot: PlaybackTimelineSnapshot {
        store.currentSnapshot
    }

    var hasObservedPlaybackInteraction: Bool {
        interactionTracker.hasObservedInteraction
    }

    var playbackInteractionRevision: UInt64 {
        interactionTracker.revision
    }

    /// 记住的过期 seek 落点上限；只用来辨认迟到的系统 time-jump，最早的先丢。
    private static let maximumStaleSeekLandings = 16

    private let player: AVPlayer
    private let store = PlaybackTimelineStore()
    private let observers = PlayerTimelineObserverBag()
    /// 当前 item 的时间线 token，由 `begin` 向 store 领取，`clear` 时置 nil。
    ///
    /// 每个 observer 捕获安装时的 token，store 丢弃与当前不符的写入，旧 item 的回调不会推进时间线。
    private var token: PlaybackTimelineItemToken?
    /// 已报告失败的 token：status 与 failedToPlayToEnd 两路失败对同一 item 只报告一次。
    private var failedToken: PlaybackTimelineItemToken?
    private var momentaryRateSession: MomentaryRateSession?
    private var pendingSeek: PendingSeek?
    /// 已收尾、但尚未观察到对应系统跳变的落点；之后落在附近的跳变按这次 seek 的迟到跳变吞掉。
    private var completedSeekLanding: SeekLanding?
    private var staleSeekLandings: [SeekLanding] = []
    private var interactionTracker = PlaybackInteractionTracker()
    private var startPositionSeconds: Double = 0

    init(player: AVPlayer) {
        self.player = player
        let initialRate = Self.validatedPlaybackRate(player.defaultRate) ?? 1
        player.defaultRate = initialRate
    }

    func updates() -> AsyncStream<PlaybackTimelineSnapshot> {
        store.updates()
    }

    func observe(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        store.observe(observer)
    }

    /// `startPositionSeconds` 是 playlist 的起播位置（从头为 0），就绪时据此标记时间轴不连续。
    func begin(
        identity: PlaybackItemIdentity,
        loadIntent: PlaybackLoadIntent = PlaybackLoadIntent(),
        startPositionSeconds: Double = 0
    ) {
        momentaryRateSession = nil
        observers.reset()
        pendingSeek = nil
        completedSeekLanding = nil
        staleSeekLandings.removeAll(keepingCapacity: true)
        self.startPositionSeconds = startPositionSeconds
        interactionTracker = PlaybackInteractionTracker(
            startPositionSeconds: startPositionSeconds
        )
        token = store.beginItem(identity: identity, loadIntent: loadIntent)
        failedToken = nil
    }

    /// 为当前 item 安装位置、速率、状态、结束、失败与时间跳变观察，并替换旧观察集合。
    func installObservers(for item: AVPlayerItem) {
        observers.reset()
        guard let token else { return }
        let interactionTracker = interactionTracker

        let periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self, weak item] time in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item,
                    let seconds = Self.seconds(from: time)
                else { return }
                self.store.update(
                    token: token,
                    positionSeconds: seconds,
                    rate: Double(self.player.rate)
                )
            }
        }

        let rateObservation = player.observe(\.rate, options: [.initial, .new]) {
            [weak self, weak item] player, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.store.update(token: token, rate: Double(player.rate))
            }
        }

        let timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self, weak item] player, change in
            let observedStatus = change.newValue ?? player.timeControlStatus
            interactionTracker.observeTimeControlStatus(
                isPaused: observedStatus == .paused,
                isPlaying: observedStatus == .playing,
                playbackRate: player.rate
            )
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                let currentState = self.store.currentSnapshot.state
                guard currentState != .failed else { return }
                switch observedStatus {
                case .paused:
                    guard currentState != .ended,
                        currentState != .loading
                            || interactionTracker.hasObservedInteraction
                    else {
                        return
                    }
                    self.store.update(token: token, rate: 0, state: .paused)
                case .waitingToPlayAtSpecifiedRate:
                    self.store.update(
                        token: token,
                        rate: Double(player.rate),
                        state: .buffering
                    )
                case .playing:
                    self.store.update(
                        token: token,
                        rate: Double(player.rate),
                        state: .playing
                    )
                @unknown default:
                    return
                }
            }
        }

        let endNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.store.update(
                    token: token,
                    positionSeconds: Self.seconds(from: item.currentTime()),
                    rate: 0,
                    state: .ended
                )
                self.momentaryRateSession = nil
            }
        }

        let statusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self, weak item] observedItem, _ in
            Task { @MainActor in
                guard observedItem.status == .failed,
                    let self,
                    let item
                else { return }
                self.fail(item: item, token: token)
            }
        }

        let failureNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item else { return }
                self.fail(item: item, token: token)
            }
        }

        let timeJumpNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item,
                    let position = Self.seconds(from: item.currentTime())
                else { return }
                self.observeTimeJump(at: position)
            }
        }

        observers.replace(
            player: player,
            periodicTimeObserver: periodicTimeObserver,
            rateObservation: rateObservation,
            timeControlObservation: timeControlObservation,
            statusObservation: statusObservation,
            endNotificationObserver: endNotificationObserver,
            failureNotificationObserver: failureNotificationObserver,
            timeJumpNotificationObserver: timeJumpNotificationObserver
        )
    }

    func markReady(duration: CMTime) {
        guard let token else { return }
        store.markReady(
            token: token,
            durationSeconds: Self.seconds(from: duration)
        )
        // 从 playlist 起播位置开始的 item 一就绪就位于该处；标记不连续，弹幕等消费方从这里排起，
        // 而不是把 0 到起播位置之间当作连续前进。
        guard startPositionSeconds > 0 else { return }
        store.markDiscontinuity(
            token: token,
            positionSeconds: Self.seconds(from: player.currentTime())
                ?? startPositionSeconds
        )
    }

    func markFailed() {
        momentaryRateSession = nil
        observers.reset()
        guard let token else { return }
        failedToken = token
        store.markFailed(token: token)
    }

    func play() {
        guard let token else { return }
        let preferredRate = Self.validatedPlaybackRate(player.defaultRate) ?? 1
        player.defaultRate = preferredRate
        player.playImmediately(atRate: preferredRate)
        store.update(
            token: token,
            rate: Double(preferredRate),
            state: .playing
        )
    }

    func playAfterInternalSeek() {
        interactionTracker.allowInternalPlayStart()
        play()
    }

    func pause() {
        guard let token else { return }
        interactionTracker.markObserved()
        momentaryRateSession = nil
        player.pause()
        store.update(token: token, rate: 0, state: .paused)
    }

    func setRate(_ rate: Double) throws {
        guard PlaybackRate.isSupported(rate) else {
            throw AVPlayerEngineError.invalidPlaybackRate
        }
        momentaryRateSession = nil
        player.defaultRate = Float(rate)
        guard player.rate > 0, let token else { return }
        player.rate = Float(rate)
        store.update(token: token, rate: rate, state: .playing)
    }

    func beginMomentaryRate(_ rate: Double) throws -> UUID? {
        guard PlaybackRate.isSupported(rate) else {
            throw AVPlayerEngineError.invalidPlaybackRate
        }
        guard let token,
            let item = player.currentItem,
            player.rate > 0
        else {
            return nil
        }

        let session = MomentaryRateSession(
            id: UUID(),
            item: item,
            rate: Float(rate)
        )
        momentaryRateSession = session
        player.rate = session.rate
        store.update(token: token, rate: rate, state: .playing)
        return session.id
    }

    func endMomentaryRate(sessionID: UUID) {
        guard let session = momentaryRateSession,
            session.id == sessionID
        else {
            return
        }
        momentaryRateSession = nil

        guard player.currentItem === session.item, let token
        else {
            return
        }
        let restorationAction = MomentaryRateRestorationPolicy.action(
            timeControlStatus: player.timeControlStatus,
            currentRate: player.rate,
            momentaryRate: session.rate
        )
        switch restorationAction {
        case .none:
            return
        case .setCurrentRate:
            player.rate = player.defaultRate
        case .resumeAtDefaultRate:
            player.play()
        }
        let restoredState: PlaybackTimelineState =
            player.timeControlStatus == .playing ? .playing : .buffering
        store.update(
            token: token,
            rate: Double(player.defaultRate),
            state: restoredState
        )
    }

    func prepareResumeRestart(operationID: UUID) {
        interactionTracker.markObservedAllowingInternalSeek(to: 0)
        beginPendingSeek(operationID: operationID, to: 0)
    }

    /// 用户或 transport 发起的 seek：先记为用户交互，再登记待定落点。
    func prepareObservedSeek(
        operationID: UUID,
        to positionSeconds: Double
    ) {
        interactionTracker.markObservedAllowingInternalSeek(to: positionSeconds)
        beginPendingSeek(operationID: operationID, to: positionSeconds)
    }

    private func beginPendingSeek(
        operationID: UUID,
        to positionSeconds: Double
    ) {
        if let pendingSeek, !pendingSeek.observedLanding {
            appendStaleSeekLanding(
                operationID: pendingSeek.operationID,
                positionSeconds: pendingSeek.targetSeconds
            )
        }
        if let completedSeekLanding {
            appendStaleSeekLanding(completedSeekLanding)
        }
        pendingSeek = PendingSeek(
            operationID: operationID,
            targetSeconds: positionSeconds
        )
        completedSeekLanding = nil
    }

    func observeTimeJump(at positionSeconds: Double) {
        interactionTracker.observeTimeJump(at: positionSeconds)
        guard store.currentSnapshot.state != .loading, let token else { return }
        if var pendingSeek {
            let currentDistance = abs(
                pendingSeek.targetSeconds - positionSeconds
            )
            if consumeStaleSeekLanding(
                at: positionSeconds,
                closerThan: currentDistance
            ) {
                return
            }
            if currentDistance <= 0.5 {
                discardEquivalentStaleSeekLandings(
                    to: pendingSeek.targetSeconds
                )
                pendingSeek.observedLanding = true
                self.pendingSeek = pendingSeek
                return
            }
            appendStaleSeekLanding(
                operationID: pendingSeek.operationID,
                positionSeconds: pendingSeek.targetSeconds
            )
            self.pendingSeek = nil
            completedSeekLanding = nil
            interactionTracker.markObserved()
            store.markDiscontinuity(
                token: token,
                positionSeconds: positionSeconds
            )
            onSeekSupersededByExternalJump?(pendingSeek.operationID)
            return
        }
        let completedDistance =
            completedSeekLanding.map {
                abs($0.positionSeconds - positionSeconds)
            } ?? .infinity
        if consumeStaleSeekLanding(
            at: positionSeconds,
            closerThan: completedDistance
        ) {
            return
        }
        if completedDistance <= 0.5 {
            if let completedSeekLanding {
                discardEquivalentStaleSeekLandings(
                    to: completedSeekLanding.positionSeconds
                )
            }
            completedSeekLanding = nil
            return
        }
        if let completedSeekLanding {
            appendStaleSeekLanding(completedSeekLanding)
        }
        completedSeekLanding = nil
        store.markDiscontinuity(
            token: token,
            positionSeconds: positionSeconds
        )
    }

    func seekFailed(operationID: UUID) {
        guard pendingSeek?.operationID == operationID else { return }
        pendingSeek = nil
        interactionTracker.cancelInternalSeek()
    }

    func discardStaleSeekLanding(operationID: UUID) {
        staleSeekLandings.removeAll {
            $0.operationID == operationID
        }
    }

    private func discardEquivalentStaleSeekLandings(to positionSeconds: Double) {
        staleSeekLandings.removeAll {
            abs($0.positionSeconds - positionSeconds) <= 0.000_001
        }
    }

    func seekCompleted(
        operationID: UUID,
        at positionSeconds: Double
    ) {
        guard let completedPendingSeek = pendingSeek,
            completedPendingSeek.operationID == operationID,
            let token
        else { return }
        pendingSeek = nil
        completedSeekLanding =
            completedPendingSeek.observedLanding
            ? nil
            : SeekLanding(
                operationID: operationID,
                positionSeconds: positionSeconds
            )
        interactionTracker.completeInternalSeek(at: positionSeconds)
        store.markDiscontinuity(
            token: token,
            positionSeconds: positionSeconds
        )
    }

    func clear() {
        momentaryRateSession = nil
        observers.reset()
        pendingSeek = nil
        completedSeekLanding = nil
        staleSeekLandings.removeAll(keepingCapacity: true)
        store.clear(token: token)
        token = nil
        failedToken = nil
    }

    private func appendStaleSeekLanding(
        operationID: UUID,
        positionSeconds: Double
    ) {
        appendStaleSeekLanding(
            SeekLanding(
                operationID: operationID,
                positionSeconds: positionSeconds
            )
        )
    }

    private func appendStaleSeekLanding(_ landing: SeekLanding) {
        staleSeekLandings.append(landing)
        if staleSeekLandings.count > Self.maximumStaleSeekLandings {
            staleSeekLandings.removeFirst()
        }
    }

    private func consumeStaleSeekLanding(
        at positionSeconds: Double,
        closerThan competingDistance: Double
    ) -> Bool {
        guard
            let candidate = staleSeekLandings.enumerated().min(
                by: {
                    abs($0.element.positionSeconds - positionSeconds)
                        < abs($1.element.positionSeconds - positionSeconds)
                }
            )
        else { return false }
        let distance = abs(candidate.element.positionSeconds - positionSeconds)
        guard distance <= 0.5, distance < competingDistance else { return false }
        staleSeekLandings.remove(at: candidate.offset)
        return true
    }

    private func fail(
        item: AVPlayerItem,
        token: PlaybackTimelineItemToken
    ) {
        guard player.currentItem === item,
            self.token == token,
            failedToken != token,
            store.currentSnapshot.state != .loading
        else { return }

        failedToken = token
        momentaryRateSession = nil
        observers.reset()
        store.markFailed(token: token)
        onFailed?()
    }

    private nonisolated static func seconds(from time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func validatedPlaybackRate(_ rate: Float) -> Float? {
        guard PlaybackRate.isSupported(rate) else { return nil }
        return rate
    }
}

/// 当前 item 的 AVPlayer 观察集合（periodic observer、KVO 与通知 observer）：替换或清空时在锁内整体
/// 换出，在锁外注销换出的旧集合；deinit 兜底注销。
///
/// 用 `OSAllocatedUnfairLock(uncheckedState:)` 而不用 `Mutex`：`replace` 要把调用方传入的 observer
/// （`Any`、`NSObjectProtocol` 等非 Sendable 值）存进锁内状态，`Mutex` 的 `inout sending` 闭包参数
/// 不允许并入这类外部值。
private final class PlayerTimelineObserverBag: Sendable {
    /// 当前观察集合；`player` 用于注销 periodic observer，其余各项各自 invalidate 或从
    /// NotificationCenter 移除。
    private struct Storage {
        var player: AVPlayer? = nil
        var periodicTimeObserver: Any? = nil
        var rateObservation: NSKeyValueObservation? = nil
        var timeControlObservation: NSKeyValueObservation? = nil
        var statusObservation: NSKeyValueObservation? = nil
        var endNotificationObserver: NSObjectProtocol? = nil
        var failureNotificationObserver: NSObjectProtocol? = nil
        var timeJumpNotificationObserver: NSObjectProtocol? = nil
    }

    private let storage = OSAllocatedUnfairLock(uncheckedState: Storage())

    deinit {
        reset()
    }

    func replace(
        player: AVPlayer,
        periodicTimeObserver: Any,
        rateObservation: NSKeyValueObservation,
        timeControlObservation: NSKeyValueObservation,
        statusObservation: NSKeyValueObservation,
        endNotificationObserver: NSObjectProtocol,
        failureNotificationObserver: NSObjectProtocol,
        timeJumpNotificationObserver: NSObjectProtocol
    ) {
        let previous = storage.withLockUnchecked { storage -> Storage in
            let previous = storage
            storage = Storage(
                player: player,
                periodicTimeObserver: periodicTimeObserver,
                rateObservation: rateObservation,
                timeControlObservation: timeControlObservation,
                statusObservation: statusObservation,
                endNotificationObserver: endNotificationObserver,
                failureNotificationObserver: failureNotificationObserver,
                timeJumpNotificationObserver: timeJumpNotificationObserver
            )
            return previous
        }
        Self.remove(previous)
    }

    func reset() {
        let previous = storage.withLockUnchecked { storage -> Storage in
            let previous = storage
            storage = Storage()
            return previous
        }
        Self.remove(previous)
    }

    private static func remove(_ storage: Storage) {
        if let player = storage.player,
            let periodicTimeObserver = storage.periodicTimeObserver
        {
            player.removeTimeObserver(periodicTimeObserver)
        }
        storage.rateObservation?.invalidate()
        storage.timeControlObservation?.invalidate()
        storage.statusObservation?.invalidate()
        if let endNotificationObserver = storage.endNotificationObserver {
            NotificationCenter.default.removeObserver(endNotificationObserver)
        }
        if let failureNotificationObserver = storage.failureNotificationObserver {
            NotificationCenter.default.removeObserver(failureNotificationObserver)
        }
        if let timeJumpNotificationObserver = storage.timeJumpNotificationObserver {
            NotificationCenter.default.removeObserver(timeJumpNotificationObserver)
        }
    }
}
