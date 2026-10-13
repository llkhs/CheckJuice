import Foundation

/// 电池种类。
///
/// ⚠️ 只决定「典型寿命」这一**弱先验**，用于冷启动。真实寿命主要由设备功耗决定，
/// 所以先验的不确定度故意给得很大（τ=0.5，≈ ±50%），几轮真实数据就能把它覆盖掉。
/// 绝不要把这里的天数当成「答案」——它只是起点。
public enum BatteryKind: String, Codable, CaseIterable, Sendable {
    case cr2032
    case cr2450
    case cr123a
    case aaAlkaline = "aa_alkaline"
    case aaLithium = "aa_lithium"
    case aaaAlkaline = "aaa_alkaline"
    case nineVolt = "9v"
    case lr44
    case builtinLithium = "builtin_li"
    case other

    /// 界面上显示的名称。
    public var displayName: String {
        switch self {
        case .cr2032: return "CR2032 纽扣锂电"
        case .cr2450: return "CR2450 纽扣锂电"
        case .cr123a: return "CR123A 锂电"
        case .aaAlkaline: return "AA 碱性"
        case .aaLithium: return "AA 锂铁"
        case .aaaAlkaline: return "AAA 碱性"
        case .nineVolt: return "9V 碱性"
        case .lr44: return "LR44 碱性纽扣"
        case .builtinLithium: return "内置锂电"
        case .other: return "其他 / 未知"
        }
    }

    /// 冷启动先验的中位寿命（**小时**）。刻意粗糙，仅用于第一颗电池的粗略估计。
    ///
    /// ⚠️ 这些数值是拍的，没有实测依据 —— 真实寿命主要由**设备功耗**决定，
    /// 同一块 CR2032 在高功耗传感器里可能只撑 4 天，在电子秤上能撑两年。
    /// 它们唯一的职责是让「刚添加、还没有任何历史」的设备有个量级正确的起点，
    /// 所以 `tauDefault` 故意给到 ±50%。攒下 2~3 次真实更换后，数据会把先验压过去。
    /// 真正的解决办法是让用户手填 / 借用同型号设备的历史（见 `nominalLifeHours`
    /// 与 `referencePrior`），而不是指望这张表。
    public var typicalLifeHours: Double {
        switch self {
        case .cr2032: return 8760            // 365 天
        case .cr2450: return 17520           // 730 天
        case .cr123a: return 21600           // 900 天
        case .aaAlkaline: return 4320        // 180 天
        case .aaLithium: return 12960        // 540 天
        case .aaaAlkaline: return 2880       // 120 天
        case .nineVolt: return 8760          // 365 天
        case .lr44: return 6480              // 270 天
        case .builtinLithium: return 26280   // 1095 天
        case .other: return 8760             // 365 天
        }
    }
}
