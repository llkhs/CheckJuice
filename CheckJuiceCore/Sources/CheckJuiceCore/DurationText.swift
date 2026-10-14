import Foundation

/// 把「小时数」写成人话。
///
/// 内部的量纲始终是小时，这里只负责显示换算 —— 与 `Prediction` 共用同一套分档阈值，
/// 免得两处各自写一遍、改一处漏一处（`ContentView.elapsedText` 原本就是第二份拷贝）。
public enum DurationText {

    /// 一段长度（间隔、已用时长）：`2 小时` / `3 天` / `5 个月`。
    ///
    /// 与 `Prediction.adaptiveHours` 的区别只在措辞：那个描述「距离耗尽」，
    /// 会带「还剩 / 约」；这里只回答「多长」。负数表示已超出，带「超出」前缀。
    public static func short(_ hours: Double) -> String {
        let h = LifetimeModel.wholeHours(hours)
        let (count, unit) = magnitudeSplit(h)
        return h < 0 ? "超出 \(count) \(unit)" : "\(count) \(unit)"
    }

    /// 量纲分档。**只在这里写一次阈值**：`adaptiveHours` 与 `short` 都用它。
    ///
    /// * ≥ 60 天 → 月（`count = h / 720`，一个月按 30 天算）
    /// * ≥ 2 天 → 天
    /// * 其余 → 小时
    ///
    /// 分档的目的是**不报假精度**：5 号电池剩 1440 小时，但 P10~P90 跨了 600 小时，
    /// 印「还剩 1443 小时」是在撒谎。
    static func magnitudeSplit(_ wholeHours: Int) -> (count: Int, unit: String) {
        let magnitude = abs(wholeHours)
        if magnitude >= 1440 {
            return (magnitude / 720, "个月")
        }
        if magnitude >= 48 {
            return (magnitude / 24, "天")
        }
        return (magnitude, "小时")
    }
}
