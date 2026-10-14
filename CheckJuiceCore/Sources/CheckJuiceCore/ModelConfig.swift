import Foundation

/// 模型超参数。集中一处，便于调参与测试。
public struct ModelConfig: Codable, Hashable, Sendable {
    /// 冷启动先验的相对不确定度。
    ///
    /// 模型唯一的先验来源是用户填的「大概能用多久」，而那本质是个人口级猜测：
    /// 刚创建设备时一次实测都没有。所以取 ±50%，诚实一点。
    /// 拿到真样本后 `sigmaPost` 会被数据压下去，这个宽度只在头几轮起作用。
    public var tauUser: Double
    /// 方差下限。
    ///
    /// 物理依据：同一台设备连换两次同款电池，寿命天然就有 15%~20% 的差异。
    /// 样本再多也不该给出「±3 小时」这种骗人的精度。
    public var sigmaMin: Double
    /// 样本不足（< `minSamplesForVariance`）时，样本方差不可识别，用此值兜底。
    public var sigmaUnidentified: Double
    /// 预测分布宽度上限，防止冷启动出现荒谬窗口。
    public var sigmaPredictionCap: Double
    /// 指数加权衰减系数。0.7 ≈ 半衰期 2 次更换。
    public var beta: Double
    /// 标准正态分布 P10 分位（取正值，公式里作减法）。
    public var z10: Double
    /// 至少多少个有效间隔，才敢相信样本方差。
    public var minSamplesForVariance: Int

    // ── 间隔合理性下限（护栏）──────────────────────────────────────────
    //
    // 真实事故：用户填「100 天」，添加后 2 分钟就点了「自然耗尽」。
    // 模型把这 2 分钟当成一次真实寿命观测 —— 它带着 11 倍于先验的精度权重，
    // 后验中位寿命从 100 天直接塌到 39 分钟。
    //
    // 一段间隔短于下限，说明它不可能是「一颗电池的真实寿命」，只能是误触 /
    // 修正 / 测试。这类间隔**不进寿命统计，但照样重置起算点**（当时确实装上了新电池）。
    //
    /// 下限的绝对上限：不足这么久必然是误触。
    public var sampleFloorHours: Double
    /// 下限相对标称寿命的比例。见 ``sampleFloorHours(for:)``。
    public var sampleFloorFraction: Double

    /// 这台设备的「间隔太短」下限。**单位：小时。**
    ///
    /// 取 `min(绝对上限, 标称寿命 × 比例)`：
    ///
    /// * 100 天的电池 → `min(1h, 240h)` = **1 小时**
    /// * 4 小时的电池 → `min(1h, 24min)` = **24 分钟**（放宽，别把真实的短周期当垃圾）
    ///
    /// 纯绝对阈值会把 4 小时电池的真实周期误杀，所以对极短寿命的设备按比例放宽。
    public func sampleFloor(for device: Device) -> Double {
        let nominal = max(device.nominalLifeHours, 1)
        return min(sampleFloorHours, sampleFloorFraction * nominal)
    }

    public init(
        tauUser: Double = 0.5,
        sigmaMin: Double = 0.15,
        sigmaUnidentified: Double = 0.30,
        sigmaPredictionCap: Double = 0.70,
        beta: Double = 0.7,
        z10: Double = 1.2815515655446004,
        minSamplesForVariance: Int = 3,
        sampleFloorHours: Double = 1.0,
        sampleFloorFraction: Double = 0.10
    ) {
        self.tauUser = tauUser
        self.sigmaMin = sigmaMin
        self.sigmaUnidentified = sigmaUnidentified
        self.sigmaPredictionCap = sigmaPredictionCap
        self.beta = beta
        self.z10 = z10
        self.minSamplesForVariance = minSamplesForVariance
        self.sampleFloorHours = sampleFloorHours
        self.sampleFloorFraction = sampleFloorFraction
    }

    public static let standard = ModelConfig()
}
