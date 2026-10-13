import Foundation

/// 模型超参数。集中一处，便于调参与测试。
public struct ModelConfig: Sendable, Equatable {
    /// 冷启动先验的相对不确定度（±50%）。
    public var tauDefault: Double
    /// 用户手填寿命时的先验不确定度。
    public var tauUser: Double
    /// 借用同型号设备历史时的先验不确定度。
    public var tauReference: Double
    /// 方差下限。
    ///
    /// 物理依据：同一台设备连换两次同型号电池，寿命天然就有 15%~20% 的差异。
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

    public init(
        tauDefault: Double = 0.5,
        tauUser: Double = 0.35,
        tauReference: Double = 0.25,
        sigmaMin: Double = 0.15,
        sigmaUnidentified: Double = 0.30,
        sigmaPredictionCap: Double = 0.70,
        beta: Double = 0.7,
        z10: Double = 1.2815515655446004,
        minSamplesForVariance: Int = 3
    ) {
        self.tauDefault = tauDefault
        self.tauUser = tauUser
        self.tauReference = tauReference
        self.sigmaMin = sigmaMin
        self.sigmaUnidentified = sigmaUnidentified
        self.sigmaPredictionCap = sigmaPredictionCap
        self.beta = beta
        self.z10 = z10
        self.minSamplesForVariance = minSamplesForVariance
    }

    public static let standard = ModelConfig()
}
