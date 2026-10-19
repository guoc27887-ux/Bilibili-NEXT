import Foundation

/// 把同一事件源分发给多个 `AsyncStream` 订阅者：每次 `subscribe` 得到独立 continuation。
///
/// 拥有订阅表；不拥有事件的去重、身份校验或回放策略，这些由发布方决定（时间线 store 让新订阅
/// 先收到当前快照，播放失败事件不回放）。某个订阅者结束迭代或被取消只移除它自己的 continuation，
/// 不影响其他订阅者；owner 释放时 `deinit` 结束全部订阅。每个订阅只缓冲最新一个值。
@MainActor
package final class AsyncBroadcast<Element: Sendable> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    package init() {}

    deinit {
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    /// 返回前登记，此后 `yield` 的值都会送达；`initial` 只先送给这一个新订阅者，不广播给已有订阅。
    package func subscribe(startingWith initial: Element?) -> AsyncStream<Element> {
        let subscriptionID = UUID()
        let stream = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[subscriptionID] = stream.continuation
        if let initial {
            stream.continuation.yield(initial)
        }
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations.removeValue(forKey: subscriptionID)
            }
        }
        return stream.stream
    }

    package func yield(_ element: Element) {
        for continuation in continuations.values {
            continuation.yield(element)
        }
    }
}
