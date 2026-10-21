import Foundation

/// 把「小时数」写成人话。
///
/// 内部的量纲始终是小时，这里只负责显示换算。
///
/// ⚠️ 分档阈值与 `Prediction.adaptiveHours` **必须保持一致**，
/// 但**不要再抽一个共用的 `magnitudeSplit`** —— 两者的措辞规则不同
/// （这个说「多长」，那个说「还剩 / 约 / 耗尽中」），
/// 硬抽成共用函数只会让两边都变难读。真要改档位，两处一起改，`RemainingTextTests` 会盯着。
public enum DurationText {

    /// 一段长度（间隔、已用时长）：`2 小时` / `3 天` / `5 个月` / `22 分钟`。
    ///
    /// 与 `Prediction.adaptiveHours` 的区别只在措辞：那个描述「距离耗尽」，
    /// 会带「还剩 / 约」；这里只回答「多长」。负数表示已超出，带「超出」前缀。
    public static func short(_ hours: Double) -> String {
        guard hours.isFinite else { return "—" }

        // 符号用原始值判断，不能先截断 —— `wholeHours(-0.9)` == 0，
        // 那样「超出 54 分钟」会变成「0 小时」。
        let exceeded = hours < 0
        let magnitude = abs(hours)

        let body: String
        if magnitude >= 1440 {
            body = "\(Int(magnitude / 720)) 个月"      // 一个月按 30 天算
        } else if magnitude >= 48 {
            body = "\(Int(magnitude / 24)) 天"
        } else if magnitude >= 1 {
            body = "\(Int(magnitude)) 小时"            // 朝零截断
        } else {
            // 不足 1 小时改用分钟。没有这一档时，「已用 22 分钟」会显示成「已用 0 小时」。
            let minutes = Int(magnitude * 60)
            body = minutes >= 1 ? "\(minutes) 分钟" : "不足 1 分钟"
        }
        return exceeded ? "超出 \(body)" : body
    }
}
