import Foundation

/// 一套可切换的模型参数。
///
/// ## 为什么是「参数」而不是「算法」
///
/// iOS **不允许下载并执行代码**（App Store 审核条款 2.5.2，且没有 JIT）。
/// 所以「把两套算法代码放 git，App 按 URL 拉下来跑」这条路在 iOS 上是**死的**，
/// 任何说能这么干的教程都是错的。
///
/// 但本模型的结构本来就是固定死的：对数正态 + 正态共轭。
/// 真正会变的只有几个数——`tauUser`（先验多不确定）、`sigmaMin`（方差下限）、
/// `sigmaUnidentified`（样本不足时的兜底 σ）、`sigmaPredictionCap`（预测 σ 上限）、
/// `beta`（指数加权的新旧样本权重）。
///
/// 把这几个数打包成 JSON，就是一套「模型」。这跟 Core ML 的权重属于**数据**、
/// 不属于代码，是同一个道理，不受 2.5.2 限制。
///
/// ## 代价
///
/// **换得了参数，换不了算法。** 真要换一套新算法（比如卡尔曼滤波），还是得发新版 App。
///
/// ## 目前的状态
///
/// 只有内置的 ``standard`` 一个，没有界面可切换，也**还没有**从 URL 拉取——
/// 但 JSON 格式由本类型定死：同一个 `Codable` 既能内置，也能直接反序列化远程 JSON。
/// 以后加「拉取 + 校验 + 切换」是纯增量，不需要动这里。
public struct ModelPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var config: ModelConfig

    public init(id: String, name: String, summary: String, config: ModelConfig) {
        self.id = id
        self.name = name
        self.summary = summary
        self.config = config
    }
}

extension ModelPreset {
    /// 内置预设，所有设备默认用它。
    ///
    /// 参数本身只有一处定义（``ModelConfig/standard``），这里只挂上给人看的
    /// 名字和说明——这样「默认参数」和「默认预设」不会各存一份而漂移。
    public static let standard = ModelPreset(
        id: "standard",
        name: "默认",
        summary: "手填寿命当先验，±50% 起步，真样本进来后自然收窄。",
        config: .standard
    )
}
