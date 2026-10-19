import Foundation

/// 用户在搜索框里输入的词（视频搜索与联想、稍后再看的关键词）的唯一规范化规则。
///
/// 去掉首尾空白；按字符计超过 `maximumLength` 的输入不发请求。联想会发送未提交的输入，见 SECURITY-MODEL §3。
public enum SearchText {
    /// 长度上限（按字符计）：远超实际用途，只用来拒绝异常输入；调小会拒绝正常的长查询，调大放宽发往服务端的输入。
    public static let maximumLength = 100

    /// 去掉首尾空白后的输入。
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 规范化后的输入不超过长度上限。
    public static func isWithinLimit(_ normalizedText: String) -> Bool {
        normalizedText.count <= maximumLength
    }
}
