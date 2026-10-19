import BiliModels
import BiliNetworking
import Foundation

/// 一次 SIDX 读取的结果：成功的来源、`Content-Range` 给出的完整长度（缺失时为 nil）与解析出的索引。
///
/// `sourceURL` 是该 representation 之后 init、分段与 Range 的唯一来源，不跨来源拼字节。
public struct LoadedSegmentIndex: Sendable, Equatable {
    public let sourceURL: URL
    public let completeMediaLength: Int64?
    public let index: SegmentIndex

    public init(
        sourceURL: URL,
        completeMediaLength: Int64?,
        index: SegmentIndex
    ) {
        self.sourceURL = sourceURL
        self.completeMediaLength = completeMediaLength
        self.index = index
    }
}

/// 从候选 CDN 严格读取并解析 SIDX，同时保留实际成功的来源供媒体代理复用。
///
/// 超过 `SIDXParser.maximumBoxByteCount` 的 `index_range` 在发起任何请求前失败。
public struct RepresentationIndexLoader: Sendable {
    private let rangeClient: HTTPRangeClient
    private let parser: SIDXParser

    public init(
        rangeClient: HTTPRangeClient = HTTPRangeClient(),
        parser: SIDXParser = SIDXParser()
    ) {
        self.rangeClient = rangeClient
        self.parser = parser
    }

    public func load(
        for representation: MediaRepresentation,
        headers: [String: String] = [:]
    ) async throws -> LoadedSegmentIndex {
        let indexRange = representation.segmentBase.index
        let boxStartOffset = UInt64(indexRange.start)
        let range = try HTTPByteRange(
            start: indexRange.start,
            endInclusive: indexRange.endInclusive
        )
        guard range.length <= UInt64(SIDXParser.maximumBoxByteCount) else {
            throw SIDXParserError.indexTooLarge(byteCount: range.length)
        }
        let response = try await rangeClient.fetch(
            from: representation.urlCandidates,
            range: range,
            headers: headers,
            // 正文解析不出 SIDX 的候选按失败处理，换下一个候选。
            validateBody: { data in
                (try? parser.parse(
                    data,
                    boxStartOffset: boxStartOffset
                )) != nil
            }
        )
        let index = try parser.parse(
            response.body,
            boxStartOffset: boxStartOffset
        )

        return LoadedSegmentIndex(
            sourceURL: response.sourceURL,
            completeMediaLength: response.contentRange.completeLength,
            index: index
        )
    }
}
