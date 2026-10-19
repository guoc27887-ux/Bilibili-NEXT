import Foundation
import Synchronization

/// 测速 Range 读取的结果：已验证的 `Content-Range`、精确字节数与请求耗时；只有要求保留时才带正文。
public struct HTTPBoundedRangeResult: Sendable, Equatable {
    public let contentRange: HTTPContentRange
    public let body: Data?
    public let byteCount: UInt64
    public let requestDurationSeconds: Double

    public init(
        contentRange: HTTPContentRange,
        body: Data?,
        byteCount: UInt64,
        requestDurationSeconds: Double
    ) {
        self.contentRange = contentRange
        self.body = body
        self.byteCount = byteCount
        self.requestDurationSeconds = requestDurationSeconds
    }
}

/// 线路测速使用的单来源有界 Range 读取 port，生产实现是 `HTTPBoundedRangeClient`。
///
/// `invalidate()` 由测速的 owner 在结束或取消时调用，取消在途请求并作废 session；
/// 默认实现什么都不做。
public protocol HTTPBoundedRangeFetching: Sendable {
    func fetch(
        from url: URL,
        range: HTTPByteRange,
        headers: [String: String],
        collectBody: Bool
    ) async throws -> HTTPBoundedRangeResult

    func invalidate()
}

extension HTTPBoundedRangeFetching {
    public func invalidate() {}
}

/// 单来源、流式且有界的 Range client，供显式媒体测速使用。
///
/// transport 在允许正文前即验证 `206`、`Content-Range` 与 `Content-Length`。因此 `200`、
/// 缺少长度或声明越界的响应会立即取消；正文只计数或按需保留，达到精确上限即停止。
public struct HTTPBoundedRangeClient: HTTPBoundedRangeFetching, Sendable {
    private let transport: URLSessionRangeTransport
    private let urlPolicy: PublicHTTPSURLPolicy

    public init(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        urlPolicy: PublicHTTPSURLPolicy = PublicHTTPSURLPolicy()
    ) {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        transport = URLSessionRangeTransport(configuration: configuration)
        self.urlPolicy = urlPolicy
    }

    init(
        transport: URLSessionRangeTransport,
        urlPolicy: PublicHTTPSURLPolicy = PublicHTTPSURLPolicy()
    ) {
        self.transport = transport
        self.urlPolicy = urlPolicy
    }

    public func fetch(
        from url: URL,
        range: HTTPByteRange,
        headers: [String: String] = [:],
        collectBody: Bool = false
    ) async throws -> HTTPBoundedRangeResult {
        guard urlPolicy.allows(url) else {
            throw HTTPRangeResponseError.disallowedURL
        }
        return try await transport.run(
            .rangeGET(url, rangeHeader: range.headerValue, headers: headers),
            operation: BoundedRangeOperation(
                validator: HTTPRangeResponseValidator(
                    expectedRange: range,
                    requiresContentLength: true
                ),
                collectBody: collectBody
            )
        )
    }

    public func invalidate() {
        transport.invalidate()
    }
}

/// 一次有界 Range 请求：验证响应头、计数或保留正文，达到精确长度即得出结果。
///
/// 拥有 data task 与结束回调，直到 `finish` 把它们取出：取消 task、解除 transport 登记，再交付唯一
/// 结果。可变状态只经 `Mutex` 访问；task 的取消与回调都在锁外执行。
private final class BoundedRangeOperation: URLSessionRangeOperation, Sendable {
    /// 一次请求的 task、结束回调、计时、已验证的响应头与计数；只在 `state` 锁内读写。
    private struct State {
        var task: URLSessionDataTask?
        var onFinish: (@Sendable () -> Void)?
        var startedAt: ContinuousClock.Instant?
        var contentRange: HTTPContentRange?
        var received: UInt64 = 0
        var retained: Data?
        var pendingResult: HTTPBoundedRangeResult?
        var finished = false
    }

    private let state: Mutex<State>
    private let validator: HTTPRangeResponseValidator
    private let expectedRange: HTTPByteRange
    private let collectBody: Bool
    private let clock = ContinuousClock()
    private let outcome = OneShotResult<HTTPBoundedRangeResult>()

    init(
        validator: HTTPRangeResponseValidator,
        collectBody: Bool
    ) {
        self.validator = validator
        expectedRange = validator.expectedRange
        self.collectBody = collectBody
        state = Mutex(State(retained: collectBody ? Data() : nil))
    }

    func start(
        _ task: URLSessionDataTask,
        onFinish: @escaping @Sendable () -> Void
    ) async throws -> HTTPBoundedRangeResult {
        let shouldStart = state.withLock { state in
            guard !state.finished else { return false }
            state.task = task
            state.onFinish = onFinish
            state.startedAt = clock.now
            return true
        }
        if shouldStart {
            task.resume()
        } else {
            task.cancel()
            onFinish()
        }
        return try await outcome.value()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func receive(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            let validated = try validator.validate(response)
            state.withLock { state in
                state.contentRange = validated.contentRange
            }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func receive(_ data: Data) {
        var outcome: Result<HTTPBoundedRangeResult, any Error>?
        state.withLock { state in
            guard !state.finished else { return }
            let next = state.received + UInt64(data.count)
            guard next <= expectedRange.length, state.pendingResult == nil else {
                outcome = .failure(
                    HTTPRangeResponseError.bodyLengthMismatch(
                        expected: expectedRange.length,
                        actual: next
                    )
                )
                return
            }
            state.retained?.append(data)
            state.received = next
            guard state.received == expectedRange.length,
                let contentRange = state.contentRange,
                let startedAt = state.startedAt
            else { return }
            let completedAt = clock.now
            state.pendingResult =
                HTTPBoundedRangeResult(
                    contentRange: contentRange,
                    body: state.retained,
                    byteCount: state.received,
                    requestDurationSeconds: max(
                        durationSeconds(startedAt.duration(to: completedAt)),
                        .leastNonzeroMagnitude
                    )
                )
        }
        if let outcome { finish(outcome) }
    }

    func complete(error: (any Error)?) {
        if let error {
            finish(
                .failure(
                    HTTPRangeResponseError.transport(
                        errorType: String(reflecting: type(of: error))
                    )
                )
            )
        } else {
            let completion = state.withLock { state in
                if let pendingResult = state.pendingResult {
                    return Result<HTTPBoundedRangeResult, any Error>.success(pendingResult)
                }
                return .failure(
                    HTTPRangeResponseError.bodyLengthMismatch(
                        expected: expectedRange.length,
                        actual: state.received
                    )
                )
            }
            finish(completion)
        }
    }

    private func finish(_ result: Result<HTTPBoundedRangeResult, any Error>) {
        let resources = state.withLock { state in
            guard !state.finished else {
                return (
                    false,
                    nil as URLSessionDataTask?,
                    nil as (@Sendable () -> Void)?
                )
            }
            state.finished = true
            let task = state.task
            state.task = nil
            let onFinish = state.onFinish
            state.onFinish = nil
            return (true, task, onFinish)
        }
        guard resources.0 else { return }
        resources.1?.cancel()
        resources.2?()
        outcome.resolve(result)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
