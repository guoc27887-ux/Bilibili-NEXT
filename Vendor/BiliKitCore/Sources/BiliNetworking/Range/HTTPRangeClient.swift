import Foundation
import Synchronization

/// 请求方声明的闭区间字节范围；构造时拒绝负起点与倒置区间，`headerValue` 是唯一的 `Range` 头写法。
public struct HTTPByteRange: Sendable, Equatable {
    public let start: Int64
    public let endInclusive: Int64

    public init(start: Int64, endInclusive: Int64) throws {
        guard start >= 0, endInclusive >= start else {
            throw HTTPByteRangeError.invalidBounds(
                start: start,
                endInclusive: endInclusive
            )
        }

        self.start = start
        self.endInclusive = endInclusive
    }

    public var headerValue: String {
        "bytes=\(start)-\(endInclusive)"
    }

    public var length: UInt64 {
        UInt64(endInclusive - start) + 1
    }
}

/// `HTTPByteRange` 的构造失败。
public enum HTTPByteRangeError: Error, Sendable, Equatable {
    case invalidBounds(start: Int64, endInclusive: Int64)
}

/// 上游 `Content-Range` 的解析结果。
///
/// 只接受 `bytes` 单位、合法闭区间与大于终点的完整长度（`*` 表示未知）。
public struct HTTPContentRange: Sendable, Equatable {
    public let start: Int64
    public let endInclusive: Int64
    public let completeLength: Int64?

    public init(start: Int64, endInclusive: Int64, completeLength: Int64?) throws {
        guard start >= 0, endInclusive >= start else {
            throw HTTPContentRangeError.invalidValue
        }
        if let completeLength, completeLength <= endInclusive {
            throw HTTPContentRangeError.invalidValue
        }

        self.start = start
        self.endInclusive = endInclusive
        self.completeLength = completeLength
    }

    public static func parse(_ value: String) throws -> Self {
        let unitAndValue = value.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard unitAndValue.count == 2,
            unitAndValue[0].lowercased() == "bytes"
        else {
            throw HTTPContentRangeError.invalidValue
        }

        let rangeAndLength = unitAndValue[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndLength.count == 2 else {
            throw HTTPContentRangeError.invalidValue
        }

        let bounds = rangeAndLength[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
            let start = Int64(bounds[0]),
            let endInclusive = Int64(bounds[1])
        else {
            throw HTTPContentRangeError.invalidValue
        }

        let completeLength: Int64?
        if rangeAndLength[1] == "*" {
            completeLength = nil
        } else {
            guard let parsedLength = Int64(rangeAndLength[1]) else {
                throw HTTPContentRangeError.invalidValue
            }
            completeLength = parsedLength
        }

        return try Self(
            start: start,
            endInclusive: endInclusive,
            completeLength: completeLength
        )
    }
}

/// `Content-Range` 无法解析或不合法。
public enum HTTPContentRangeError: Error, Sendable, Equatable {
    case invalidValue
}

/// `HTTPRangeClient` 一次成功读取的来源、已验证的 `Content-Range` 与长度精确的正文。
public struct HTTPRangeFetchResult: Sendable, Equatable {
    public let sourceURL: URL
    public let contentRange: HTTPContentRange
    public let body: Data

    public init(sourceURL: URL, contentRange: HTTPContentRange, body: Data) {
        self.sourceURL = sourceURL
        self.contentRange = contentRange
        self.body = body
    }
}

/// 一个候选来源的失败记录：候选 URL 与失败分类，不含响应正文或底层错误文本。
public struct HTTPRangeAttempt: Sendable, Equatable {
    public let url: URL
    public let failure: HTTPRangeResponseError

    public init(url: URL, failure: HTTPRangeResponseError) {
        self.url = url
        self.failure = failure
    }
}

/// `HTTPRangeClient` 的整体失败：没有候选，或全部候选失败（按尝试顺序附带记录）。
public enum HTTPRangeClientError: Error, Sendable, Equatable {
    case noCandidates
    case allCandidatesFailed([HTTPRangeAttempt])
}

/// 逐候选执行严格 HTTP Range 读取并收集正文的无状态 client。
///
/// 每个候选都经 `HTTPRangeStreaming` 先验证公共 HTTPS、精确 `206` 与 `Content-Range`，再接收正文；
/// 正文逐字节计数，超过请求长度立即取消，因此忽略 Range 的整段响应不会被读入内存，正文上限就是
/// 调用方请求的区间长度。取消立即传播，不会伪装成候选失败后继续请求其他 CDN。
public struct HTTPRangeClient: Sendable {
    private let streamer: any HTTPRangeStreaming

    public init() {
        self.init(streamer: HTTPRangeStreamingClient())
    }

    public init(streamer: any HTTPRangeStreaming) {
        self.streamer = streamer
    }

    /// 按顺序尝试来源并返回首个完全验证的响应。
    ///
    /// 失败记录包含候选 URL 与分类结果，但不保留响应正文或底层 Error 文本；因此不能直接
    /// 把 `HTTPRangeAttempt` 当作可公开日志，调用方仍须按敏感远端 URL 处理。
    public func fetch(
        from candidateURLs: [URL],
        range: HTTPByteRange,
        headers additionalHeaders: [String: String] = [:],
        validateBody: (@Sendable (Data) -> Bool)? = nil
    ) async throws -> HTTPRangeFetchResult {
        guard !candidateURLs.isEmpty else {
            throw HTTPRangeClientError.noCandidates
        }

        var attempts: [HTTPRangeAttempt] = []
        for url in candidateURLs {
            try Task.checkCancellation()
            do {
                let result = try await fetch(
                    from: url,
                    range: range,
                    headers: additionalHeaders
                )
                if let validateBody, !validateBody(result.body) {
                    throw HTTPRangeResponseError.rejectedBody
                }
                return result
            } catch {
                // 调用方取消后，上游无论以什么错误结束（含与取消竞争到达的 transport 失败）都不是
                // 候选失败，不能在最后一个候选上被归为 allCandidatesFailed。
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                attempts.append(
                    HTTPRangeAttempt(
                        url: url,
                        failure: error as? HTTPRangeResponseError
                            ?? .transport(errorType: String(reflecting: type(of: error)))
                    )
                )
            }
        }

        throw HTTPRangeClientError.allCandidatesFailed(attempts)
    }

    private func fetch(
        from url: URL,
        range: HTTPByteRange,
        headers: [String: String]
    ) async throws -> HTTPRangeFetchResult {
        let collected = CollectedRangeBody()
        _ = try await streamer.stream(
            from: url,
            rangeHeader: range.headerValue,
            expectedRange: range,
            expectedCompleteLength: nil,
            headers: headers,
            allowedContentTypes: nil,
            requiresContentLength: false,
            onResponse: { collected.accept($0.contentRange) },
            onChunk: { collected.append($0) }
        )
        let (contentRange, body) = collected.snapshot
        guard let contentRange else {
            throw HTTPRangeResponseError.missingContentRange
        }
        guard UInt64(body.count) == range.length else {
            throw HTTPRangeResponseError.bodyLengthMismatch(
                expected: range.length,
                actual: UInt64(body.count)
            )
        }
        return HTTPRangeFetchResult(
            sourceURL: url,
            contentRange: contentRange,
            body: body
        )
    }
}

/// 单个候选已验证的响应头与正文；streamer 保证正文不超过请求区间。
private final class CollectedRangeBody: Sendable {
    private let state = Mutex((contentRange: HTTPContentRange?.none, body: Data()))

    var snapshot: (HTTPContentRange?, Data) {
        state.withLock { ($0.contentRange, $0.body) }
    }

    func accept(_ contentRange: HTTPContentRange) {
        state.withLock { $0.contentRange = contentRange }
    }

    func append(_ chunk: Data) {
        state.withLock { $0.body.append(chunk) }
    }
}
