import BiliNetworking
import Foundation

/// 已解析的最小 HTTP/1.1 请求头：方法、去掉 query 的 origin-form 目标与小写名字的 header。
///
/// 只接受 `HTTP/1.x` 请求行与 origin-form 目标，`Host` 重复即视为畸形，见 SECURITY-MODEL §5。
struct LoopbackHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]

    static func parse(_ data: Data) throws -> Self {
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoopbackPlaybackServerError.invalidHTTPRequest
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3,
            requestLine[2].hasPrefix("HTTP/1.")
        else {
            throw LoopbackPlaybackServerError.invalidHTTPRequest
        }

        // 只接受 origin-form；query 不参与路由。
        let rawTarget = requestLine[1]
        guard rawTarget.hasPrefix("/") else {
            throw LoopbackPlaybackServerError.invalidHTTPRequest
        }
        let target = rawTarget[..<(rawTarget.firstIndex(of: "?") ?? rawTarget.endIndex)]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw LoopbackPlaybackServerError.invalidHTTPRequest
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            let normalizedName = name.lowercased()
            guard normalizedName != "host" || headers[normalizedName] == nil else {
                throw LoopbackPlaybackServerError.invalidHTTPRequest
            }
            headers[normalizedName] = value
        }
        return Self(
            method: String(requestLine[0]),
            target: String(target),
            headers: headers
        )
    }
}

/// 下游 `Range` 头的解析结果：忽略（按完整 200 响应）、可满足的单一区间或越界（416）。
enum LoopbackRangeRequest {
    case ignored
    case satisfiable(headerValue: String, resolved: HTTPByteRange)
    case unsatisfiable
}

/// 响应头的拼装与下游 `Range` 头的解析；不读写 server 状态。
extension LoopbackPlaybackServer {
    static func responseHead(
        status: Int,
        reason: String,
        headers: [String: String]
    ) -> Data {
        let head =
            (["HTTP/1.1 \(status) \(reason)"]
            + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            + ["", ""])
            .joined(separator: "\r\n")
        return Data(head.utf8)
    }

    func responseHeaders(
        for resource: LoopbackPlaybackResource,
        bodyLength: Int,
        range: HTTPByteRange?,
        isHead: Bool
    ) -> [String: String] {
        var headers = [
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "Content-Type": resource.contentType,
            "Content-Length": isHead
                ? "\(resource.contentLength)"
                : "\(bodyLength)"
        ]
        if let range {
            headers["Content-Range"] =
                "bytes \(range.start)-\(range.endInclusive)/\(resource.contentLength)"
        }
        return headers
    }

    /// 解析下游的单一 Range，见 SECURITY-MODEL §5。
    ///
    /// 多段、非 `bytes` 或写法不合法时忽略（内存资源回完整 200，远端资源回 400）；
    /// 起点越界或后缀长度为 0 时 416；终点超出时截到末尾。
    func parseRange(
        _ value: String?,
        contentLength: Int64
    ) -> LoopbackRangeRequest {
        guard let value else { return .ignored }
        let components = value.split(
            separator: "=",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
            components[0].lowercased() == "bytes",
            !components[1].contains(",")
        else {
            return .ignored
        }

        let bounds = components[1].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2 else {
            return .ignored
        }

        if bounds[0].isEmpty {
            guard let suffixLength = Int64(bounds[1]) else {
                return .ignored
            }
            guard suffixLength > 0 else {
                return suffixLength == 0 ? .unsatisfiable : .ignored
            }
            let boundedLength = min(suffixLength, contentLength)
            guard
                let range = try? HTTPByteRange(
                    start: contentLength - boundedLength,
                    endInclusive: contentLength - 1
                )
            else {
                return .ignored
            }
            return .satisfiable(headerValue: value, resolved: range)
        }

        guard let start = Int64(bounds[0]), start >= 0 else {
            return .ignored
        }
        guard start < contentLength else {
            return .unsatisfiable
        }

        let endInclusive: Int64
        if bounds[1].isEmpty {
            endInclusive = contentLength - 1
        } else {
            guard let requestedEnd = Int64(bounds[1]), requestedEnd >= start else {
                return .ignored
            }
            endInclusive = min(requestedEnd, contentLength - 1)
        }
        guard
            let range = try? HTTPByteRange(
                start: start,
                endInclusive: endInclusive
            )
        else {
            return .ignored
        }
        return .satisfiable(headerValue: value, resolved: range)
    }
}
