import BiliModels

/// HLS `BANDWIDTH` 的峰值码率：任意连续分段在总时长落在目标时长 0.5–1.5 倍之间时的最大码率。
///
/// 逐个起点累加窗口是 O(n²)，病态 SIDX（大量极短分段加一个极长分段）会让播放准备长时间占满 CPU
/// 且无法取消。这里用 Dinkelbach 迭代把“最大比值”化为若干轮“最大差值”：每轮以双指针维护时长合法的
/// 起点区间、用单调队列取区间内的最小前缀，单轮 O(n)；比值每轮严格上升，通常两三轮收敛。时长与比特数
/// 全部用整数 tick 与 bit 精确比较，结果是某个合法窗口精确码率的整数向上取整，与并列窗口的选择无关。
enum HLSPeakBitRate {
    /// 前缀和上限；乘积保持在 `Int128` 范围内，超出说明 SIDX 声明的数值不可能是真实媒体。
    private static let maximumPrefixTotal = Int128(1) << 62

    /// 返回向上取整的 bit/s。
    ///
    /// 调用方已验证非空分段、正 timescale 与正时长；没有满足时长约束的窗口或结果超出 `Int` 时
    /// 抛 `invalidCalculatedBitRate`。
    static func peak(of index: SegmentIndex) throws -> Int {
        let references = index.references
        let count = references.count
        guard count > 0, index.timescale > 0 else {
            throw HLSPlaylistBuilderError.invalidCalculatedBitRate
        }
        let timescale = Int128(index.timescale)
        // 目标时长是最长分段时长向上取整的整秒数。
        let targetDuration =
            references.map { (Int128($0.duration) + timescale - 1) / timescale }.max() ?? 0
        // 窗口时长 T（tick）合法当且仅当 0.5·target ≤ T/timescale ≤ 1.5·target，两边乘 2 化为整数。
        let doubledMinimum = targetDuration * timescale
        let doubledMaximum = 3 * targetDuration * timescale

        var bitPrefix = [Int128](repeating: 0, count: count + 1)
        var tickPrefix = [Int128](repeating: 0, count: count + 1)
        for (offset, reference) in references.enumerated() {
            // MediaByteRange 保证 endInclusive ≥ start，因此每个分段至少 1 字节；下面的迭代终止
            // 条件也不依赖这一点。
            let byteCount =
                Int128(reference.byteRange.endInclusive)
                - Int128(reference.byteRange.start) + 1
            bitPrefix[offset + 1] = bitPrefix[offset] + byteCount * 8
            tickPrefix[offset + 1] = tickPrefix[offset] + Int128(reference.duration)
        }
        guard bitPrefix[count] < maximumPrefixTotal,
            tickPrefix[count] < maximumPrefixTotal
        else {
            throw HLSPlaylistBuilderError.invalidCalculatedBitRate
        }

        // 当前最优比值 bits/ticks，初值 0/1；`hasWindow` 表示它已来自真实窗口。
        var bits: Int128 = 0
        var ticks: Int128 = 1
        var hasWindow = false
        var weightedPrefix = [Int128](repeating: 0, count: count + 1)
        var queue = [Int](repeating: 0, count: count + 1)
        while true {
            for position in 0...count {
                weightedPrefix[position] =
                    ticks * bitPrefix[position] - bits * tickPrefix[position]
            }
            var head = 0
            var tail = 0
            var nextStart = 0
            var best: (gain: Int128, start: Int, end: Int)?
            for end in 1...count {
                while nextStart < end,
                    2 * (tickPrefix[end] - tickPrefix[nextStart]) >= doubledMinimum
                {
                    while tail > head,
                        weightedPrefix[queue[tail - 1]] >= weightedPrefix[nextStart]
                    {
                        tail -= 1
                    }
                    queue[tail] = nextStart
                    tail += 1
                    nextStart += 1
                }
                while tail > head,
                    2 * (tickPrefix[end] - tickPrefix[queue[head]]) > doubledMaximum
                {
                    head += 1
                }
                guard tail > head else { continue }
                let start = queue[head]
                let gain = weightedPrefix[end] - weightedPrefix[start]
                if best.map({ gain > $0.gain }) ?? true {
                    best = (gain, start, end)
                }
            }
            guard let best else {
                throw HLSPlaylistBuilderError.invalidCalculatedBitRate
            }
            // 没有窗口的比值能超过当前窗口即为最优；否则换到增益最大的窗口，比值严格上升，
            // 窗口有限，因此迭代必然终止（即使出现 0 字节分段）。
            if hasWindow, best.gain <= 0 {
                return try ceilingBitRate(bits: bits, ticks: ticks, timescale: timescale)
            }
            bits = bitPrefix[best.end] - bitPrefix[best.start]
            ticks = tickPrefix[best.end] - tickPrefix[best.start]
            hasWindow = true
        }
    }

    /// `ceil(bits × timescale ÷ ticks)`，在 `Int128` 内精确计算。
    private static func ceilingBitRate(
        bits: Int128,
        ticks: Int128,
        timescale: Int128
    ) throws -> Int {
        let rate = (bits * timescale + ticks - 1) / ticks
        guard rate > 0, rate <= Int128(Int.max) else {
            throw HLSPlaylistBuilderError.invalidCalculatedBitRate
        }
        return Int(rate)
    }
}
