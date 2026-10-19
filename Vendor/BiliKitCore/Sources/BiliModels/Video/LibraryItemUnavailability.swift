import Foundation

/// 资料库条目（稍后再看、收藏夹）不能在 BiliKit 里播放的原因。
///
/// 只描述接口给出的事实，由 BiliAPI 的条目映射判定；卡片角标、占位标题与读屏文案只在 Library 的
/// `LibraryUnavailabilityFormatting`。充电专属不在这里：播放页自己处理完整播放、试看与提示。
public enum LibraryItemUnavailability: Sendable, Equatable {
    /// 已失效（稍后再看 `state < 0`；收藏夹 `attr` 的 bit0 为 1，或标题为“已失效视频”／“该合集已失效”）。
    case invalid
    /// 番剧、影视等 PGC 内容（稍后再看 `is_pgc` 或 `pgc_label`，收藏夹 `ogv` 非空）；`label` 是接口给的分类原文
    /// （`pgc_label`、`ogv.type_name`），空时为 nil。
    case pgc(label: String?)
    /// 课程（`is_pugv` 为真）。
    case course
    /// 收藏的合集（收藏夹 type 21）。
    case collection
    /// 收藏的音频（收藏夹 type 12）。
    case audio
    /// 收藏夹里其他未知类型的条目。
    case unsupported
}
