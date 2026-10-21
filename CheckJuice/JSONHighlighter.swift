import SwiftUI
import UIKit

/// 极简 JSON 语法着色。
///
/// **不引第三方库**：要好处的只是「键/字符串/数字/字面量各一个颜色」，
/// 为这点事拖一个高亮框架进来，代价远大于收益。
///
/// ### 性能设计（第一版在这里翻了车）
///
/// 第一版是「逐 token 建 `AttributedString` 再 `+=`」。4.7 KB 的文件就有
/// **2195 次分配 + 拼接**，而且 `default` 分支逐字符走 —— 每个空格、换行都单独
/// 分配一次。按同样密度推算，200 KB 时约 **9.4 万次**，全在主线程上，必然卡住。
/// 那个 200 KB 上限其实是在给一个错的实现兜底。
///
/// 现在的做法：
/// 1. 扫描出 `(区间, 颜色)`，**相邻同色直接合并**（实测减少约 58% 的项数）；
/// 2. 只构造**一次** `NSMutableAttributedString`，逐段设属性（区间存储，不复制字符）；
/// 3. 整个着色跑在**后台线程**，主线程只负责最终赋值。
///
/// 用 `UIColor` 的系统语义色（`.systemPurple` 等）而不是 SwiftUI 的 `Color`：
/// 它们是动态色，自动适配深色模式和「增强对比度」，也不需要在后台线程碰 SwiftUI 环境。
enum JSONHighlighter {

    /// 超过这个长度就直接出纯文本。
    ///
    /// 虽然改成区间着色后快了一个数量级，但设备几百台时导出能有几百 KB，
    /// 而预览页只需要看得清结构 —— 不值得为极限情况把实现搞复杂。
    private static let maxBytes = 512_000

    /// token 类别。
    ///
    /// **合并相邻段时比较的是这个枚举，不是 `UIColor` 实例** ——
    /// 拿颜色对象做相等判断要依赖「同一系统色返回同一实例」这个实现细节，
    /// 而那不属于公开契约。枚举比较是确定的。
    private enum Kind {
        case key, string, number, literal, punct, plain

        var color: UIColor {
            switch self {
            case .key: return .systemPurple
            case .string: return .systemRed
            case .number: return .systemBlue
            case .literal: return .systemOrange
            case .punct: return .secondaryLabel
            case .plain: return .label
            }
        }
    }

    /// 着色。**可以在任何线程调用**（不碰 SwiftUI 状态）。
    static func attributed(_ source: String) -> AttributedString {
        guard source.utf8.count <= maxBytes else {
            return AttributedString(source)
        }

        var segments: [(range: Range<String.Index>, kind: Kind)] = []
        segments.reserveCapacity(source.utf8.count / 8)

        /// 追加一段。相邻且同色的**直接并进上一段** ——
        /// 这是把 3238 项压到 1355 项的关键。
        func add(_ range: Range<String.Index>, _ kind: Kind) {
            if let last = segments.last, last.kind == kind, last.range.upperBound == range.lowerBound {
                segments[segments.count - 1].range = last.range.lowerBound..<range.upperBound
            } else {
                segments.append((range, kind))
            }
        }

        var i = source.startIndex
        let end = source.endIndex

        while i < end {
            let ch = source[i]

            switch ch {
            case "\"":
                // 字符串：扫到配对的双引号，处理 `\"` 转义。
                var j = source.index(after: i)
                var escaped = false
                while j < end {
                    let c = source[j]
                    if escaped {
                        escaped = false
                    } else if c == "\\" {
                        escaped = true
                    } else if c == "\"" {
                        j = source.index(after: j)
                        break
                    }
                    j = source.index(after: j)
                }

                // 键的判定：跳过空白后**紧跟冒号**才是键。
                // 不能看字符串内容里有没有冒号 —— 否则 `{"a": "key: not a key"}`
                // 会把值误判成键。
                var k = j
                while k < end, source[k] == " " || source[k] == "\t" {
                    k = source.index(after: k)
                }
                let isKey = k < end && source[k] == ":"
                add(i..<j, isKey ? .key : .string)
                i = j

            case "-", "0"..."9":
                var j = i
                while j < end, "0123456789+-.eE".contains(source[j]) {
                    j = source.index(after: j)
                }
                if j == i { j = source.index(after: i) }   // 防御：保证前进
                add(i..<j, .number)
                i = j

            case "t", "f", "n":
                // true / false / null
                let rest = source[i...]
                if let literal = ["true", "false", "null"].first(where: { rest.hasPrefix($0) }) {
                    let j = source.index(i, offsetBy: literal.count)
                    add(i..<j, .literal)
                    i = j
                } else {
                    add(i..<source.index(after: i), .plain)
                    i = source.index(after: i)
                }

            case "{", "}", "[", "]", ":", ",":
                add(i..<source.index(after: i), .punct)
                i = source.index(after: i)

            default:
                // 空白、换行以及其它非结构字符。走这里时**成段吃掉**，
                // 不再逐字符 —— 第一版就是在这里把分配次数撑到几万次的。
                var j = source.index(after: i)
                while j < end, !Self.isStructural(source[j]) {
                    j = source.index(after: j)
                }
                add(i..<j, .plain)
                i = j
            }
        }

        // 只构造一次字符串，然后逐段设属性（区间存储，不复制字符）。
        let attributed = NSMutableAttributedString(string: source)
        for segment in segments {
            attributed.addAttribute(
                .foregroundColor,
                value: segment.kind.color,
                range: NSRange(segment.range, in: source)
            )
        }
        return AttributedString(attributed)
    }

    /// 会开启新 token 的字符。`default` 分支靠它判断「这一整段普通字符到哪儿结束」。
    private static func isStructural(_ ch: Character) -> Bool {
        switch ch {
        case "\"", "-", "0"..."9", "t", "f", "n", "{", "}", "[", "]", ":", ",":
            return true
        default:
            return false
        }
    }
}
