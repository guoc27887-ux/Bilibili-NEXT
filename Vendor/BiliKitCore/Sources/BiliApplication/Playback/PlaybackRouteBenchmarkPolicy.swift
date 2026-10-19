/// 线路测速一次可用的样本数，设置界面的选项、BiliAPI 的样本发现与 BiliPlayback 的测速都只读这一份。
///
/// 每多一个样本，测速的流量与时长都再加一整轮（设置界面按样本数显示流量上限）；上限 3 限制了单次
/// 测速的最大流量。超出范围的请求在样本发现与测速两处都直接拒绝。
public enum PlaybackRouteBenchmarkPolicy {
    public static let supportedSampleCounts = 1...3
}
