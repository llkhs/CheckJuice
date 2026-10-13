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

    /// 冷启动先验的中位寿命（天）。刻意粗糙，仅用于第一颗电池的粗略估计。
    public var typicalLifeDays: Double {
        switch self {
        case .cr2032: return 365
        case .cr2450: return 730
        case .cr123a: return 900
        case .aaAlkaline: return 180
        case .aaLithium: return 540
        case .aaaAlkaline: return 120
        case .nineVolt: return 365
        case .lr44: return 270
        case .builtinLithium: return 1095
        case .other: return 365
        }
    }
}
