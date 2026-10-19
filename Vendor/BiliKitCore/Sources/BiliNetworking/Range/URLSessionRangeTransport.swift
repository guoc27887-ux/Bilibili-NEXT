import Foundation
import Synchronization

/// 单个 Range data task 的正文消费方；由 `URLSessionRangeTransport` 按 task 分发 delegate 事件。
protocol URLSessionRangeOperation: AnyObject, Sendable {
    associatedtype Output: Sendable

    /// 启动 task 并等待唯一结果；结束时必须调用 `onFinish` 解除 transport 登记。
    func start(
        _ task: URLSessionDataTask,
        onFinish: @escaping @Sendable () -> Void
    ) async throws -> Output
    func cancel()
    func receive(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    )
    func receive(_ data: Data)
    func complete(error: (any Error)?)
}

/// Range client 共用的 URLSession delegate 与 task 生命周期。
///
/// 拒绝重定向；session 在首次请求时才于锁内创建，`invalidate` 后取消在途 operation 且不再创建新 task。
/// 可变状态只经 `Mutex` 访问；operation 的 `cancel()` 与 session 失效都在锁外执行。
final class URLSessionRangeTransport: NSObject, URLSessionDataDelegate, Sendable {
    /// operation 登记表、懒创建的 session 与失效标记；只在 `state` 锁内读写。
    private struct State {
        var operations: [Int: any URLSessionRangeOperation] = [:]
        var session: URLSession?
        var isInvalidated = false

        /// 首次请求时创建 session，之后复用；在 `withLock` 闭包里对锁内状态调用，与登记 operation、
        /// 检查失效处于同一临界区。
        mutating func activeSession(
            configuration: URLSessionConfiguration,
            delegate: URLSessionRangeTransport
        ) -> URLSession {
            if let session { return session }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            let session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: queue
            )
            self.session = session
            return session
        }
    }

    private let configuration: URLSessionConfiguration
    private let state = Mutex(State())

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        super.init()
    }

    func run<Operation: URLSessionRangeOperation>(
        _ request: URLRequest,
        operation: Operation
    ) async throws -> Operation.Output {
        let task = try state.withLock { state in
            guard !state.isInvalidated else { throw CancellationError() }
            let task = state.activeSession(configuration: configuration, delegate: self)
                .dataTask(with: request)
            state.operations[task.taskIdentifier] = operation
            return task
        }
        let taskIdentifier = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await operation.start(task) { [weak self] in
                self?.state.withLock { $0.operations[taskIdentifier] = nil }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    func invalidate() {
        let (pending, session) = state.withLock { state in
            state.isInvalidated = true
            let pending = Array(state.operations.values)
            state.operations.removeAll()
            return (pending, state.session)
        }
        for operation in pending { operation.cancel() }
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let operation = operation(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        operation.receive(response, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        operation(for: dataTask.taskIdentifier)?.receive(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        operation(for: task.taskIdentifier)?.complete(error: error)
    }

    private func operation(for taskIdentifier: Int) -> (any URLSessionRangeOperation)? {
        state.withLock { $0.operations[taskIdentifier] }
    }
}
