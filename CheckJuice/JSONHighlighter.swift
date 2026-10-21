import Foundation
import UIKit

/// JSON 语法着色。
///
/// 词法规则**照搬 Prism 的 `components/prism-json.js`**（业界验证过的规则集），
/// 但用 Swift 的 `NSRegularExpression` 实现，不引入任何运行时 ——
/// 不打包 1 MB 的 highlight.min.js，也不要 JavaScriptCore。
///
/// 用 `UIColor` 的系统语义色而不是 SwiftUI 的 `Color`：
/// 前者能在后台线程安全使用（本类不碰 SwiftUI 状态，可以放到任意线程跑）。
enum JSONHighlighter {

    /// 超过这个大小就不着色，只保证能看。
    ///
    /// 512 KB 是按「几百台设备」估的上限 —— 实际一份导出只有几 KB。
    static let sizeLimit = 512 * 1024

    /// token 类别。
    ///
    /// **合并相邻段时比较的是这个枚举，不是 `UIColor` 实例** ——
    /// 拿颜色对象做相等判断要依赖「同一系统色返回同一实例」，那不属于公开契约。
    enum Kind {
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

    // MARK: - 规则（来自 Prism）

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"-?\b\d+(?:\.\d+)?(?:e[+-]?\d+)?\b"#)
    private static let literalRegex = try! NSRegularExpression(
        pattern: #"\b(?:false|true|null)\b"#)
    private static let punctRegex = try! NSRegularExpression(
        pattern: #"[{}\[\],]|:"#)

    /// 等宽字体。所有区间都设同一个实例，省得逐段重复构造。
    private static let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// 超过这个大小就不着色了，只显示纯文本。
    ///
    /// 着色本身已经是线性扫描 + 区间属性，512 KB 也不会卡；
    /// 留这个上限是防极端情况（几千台设备的导出），不是给慢实现兜底。
    private static let sizeLimit = 512 * 1024

    /// 着色。**可以在任何线程调用**（不碰 SwiftUI 状态）。
    static func attributed(_ source: String) -> AttributedString {
        let result = NSMutableAttributedString(string: source)
        let length = (source as NSString).length

        // 超限就只上字体、不上色。
        // 两条路径都从 NSMutableAttributedString 出去 ——
        // 在 `AttributedString` 上直接设 `font` 要 SwiftUI 的 attribute scope，
        // 本文件只导了 UIKit，走桥接更省事也更一致。
        if source.utf8.count <= sizeLimit {
            for segment in layout(source) {
                result.addAttribute(.foregroundColor,
                                    value: segment.kind.color,
                                    range: segment.range)
            }
        }

        result.addAttribute(.font, value: font,
                            range: NSRange(location: 0, length: length))
        return AttributedString(result)
    }

    // MARK: - 扫描

    /// 切分成不重叠、无缝隙的区间。
    ///
    /// **为什么不用 Prism 原来那套正则直接跑**：
    /// Prism 是 JS，靠引擎按位置顺序消费 token，不会回头。
    /// 在 Swift 里用 `NSRegularExpression` 一次性收集所有匹配，
    /// `"(?:\\.|[^"])*"` 会从**某个字符串的收尾引号**开始匹配，
    /// 跨过 `, ` 一直匹配到下一个字符串的开引号 —— 段就错位了。
    ///
    /// 所以顺序是：先手工切出字符串区间（正确处理转义），
    /// 再在**字符串之外**的缝隙里跑数字/字面量/标点规则。
    /// 语义与 Prism 一致（同样是「字符串优先、其余按位置」），只是实现方式更稳。
    private static func layout(_ source: String) -> [(range: NSRange, kind: Kind)] {
        let ns = source as NSString
        let length = ns.length
        guard length > 0 else { return [] }

        let strings = stringSpans(ns)
        var tokens: [(range: NSRange, kind: Kind)] = []

        for span in strings {
            // 键的判定：跳过空白后紧跟冒号。
            // 不能看内容里有没有冒号 —— `"key: not a key"` 会被误判。
            var k = span.location + span.length
            while k < length, isSpace(ns.character(at: k)) { k += 1 }
            let isKey = k < length && ns.character(at: k) == 0x3A   // ':'
            tokens.append((span, isKey ? .key : .string))
        }

        func outsideStrings(_ range: NSRange) -> Bool {
            !strings.contains { $0.location < range.location + range.length
                                && range.location < $0.location + $0.length }
        }

        func collect(_ regex: NSRegularExpression, _ kind: Kind) {
            for match in regex.matches(in: source, range: NSRange(location: 0, length: length))
            where outsideStrings(match.range) {
                tokens.append((match.range, kind))
            }
        }

        collect(numberRegex, .number)
        collect(literalRegex, .literal)
        collect(punctRegex, .punct)

        return merged(tokens, length: length)
    }

    /// 手工切字符串区间。必须处理 `\"` 转义，否则 `"he said \"hi\""` 会被截断。
    private static func stringSpans(_ ns: NSString) -> [NSRange] {
        var spans: [NSRange] = []
        let length = ns.length
        var i = 0
        while i < length {
            guard ns.character(at: i) == 0x22 else {      // '"'
                i += 1
                continue
            }
            var j = i + 1
            while j < length {
                let ch = ns.character(at: j)
                if ch == 0x5C { j += 2; continue }        // '\\' 跳过被转义的字符
                if ch == 0x22 { j += 1; break }           // '"' 收尾
                j += 1
            }
            spans.append(NSRange(location: i, length: min(j, length) - i))
            i = j
        }
        return spans
    }

    private static func isSpace(_ ch: unichar) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }

    /// 排序 → 填补空隙 → 合并相邻同类段。
    private static func merged(_ tokens: [(range: NSRange, kind: Kind)],
                               length: Int) -> [(range: NSRange, kind: Kind)] {
        let sorted = tokens.sorted {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.range.length > $1.range.length
        }

        var filled: [(range: NSRange, kind: Kind)] = []
        var cursor = 0
        for token in sorted {
            // 重叠的直接丢（长匹配已优先排过，剩下的都是被包含的短匹配）。
            guard token.range.location >= cursor else { continue }
            if token.range.location > cursor {
                filled.append((NSRange(location: cursor, length: token.range.location - cursor), .plain))
            }
            filled.append(token)
            cursor = token.range.location + token.range.length
        }
        if cursor < length {
            filled.append((NSRange(location: cursor, length: length - cursor), .plain))
        }

        var out: [(range: NSRange, kind: Kind)] = []
        for segment in filled {
            if let last = out.last, last.kind == segment.kind,
               last.range.location + last.range.length == segment.range.location {
                out[out.count - 1].range.length += segment.range.length
            } else {
                out.append(segment)
            }
        }
        return out
    }
}
