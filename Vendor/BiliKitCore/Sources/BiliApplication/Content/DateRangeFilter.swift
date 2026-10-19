import Foundation

/// 日期筛选（搜索的发布日期、稍后再看的加入时间）无法给出区间的原因，两处共用。
///
/// 自定义的开始日晚于结束日、结束日晚于今天（只有搜索要求）、区间早于 1970 年、区间为空，或日历无法推算日期。
public enum DateRangeFilterError: Error, Sendable, Equatable {
    case startAfterEnd
    case futureDate
    case beforeEpoch
    case emptyRange
    case invalidCalendarRange
}

/// 日期筛选区间换成 Unix 秒的唯一规则，搜索与稍后再看的解析共用。
///
/// 区间含开始、不含 `endExclusive`；开始早于 1970 年（接口的秒级时间戳不接受负数）或区间为空时抛错，筛选弹窗据此
/// 显示原因并禁用“应用”。
enum DateRangeFilterValidation {
    static func timestamps(
        start: Date,
        endExclusive: Date
    ) throws -> (start: Int64, endExclusive: Int64) {
        guard start.timeIntervalSince1970 >= 0 else {
            throw DateRangeFilterError.beforeEpoch
        }
        guard start < endExclusive else {
            throw DateRangeFilterError.emptyRange
        }
        return (
            Int64(start.timeIntervalSince1970),
            Int64(endExclusive.timeIntervalSince1970)
        )
    }
}
