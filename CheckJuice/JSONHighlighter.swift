import SwiftUI

/// 极简 JSON 语法着色。
///
/// **不引第三方库**：要好处的只是「键/字符串/数字/字面量各一个颜色」，
/// 为这点事拖一个 Markdown/JSON 高亮框架进来，代价远大于收益。
/// 这里就是一个线性扫描器，够用且没有依赖。
///
/// 用系统语义色（`.purple` / `.red` / `.blue` / `.orange` / `.secondary`），
/// 它们会自动跟随深色模式和「增强对比度」辅助功能设置，
/// 不用自己维护两套配色。
enum JSONHighlighter {

    /// 超过这个长度就不着色了。
    ///
    /// 着色是逐字符扫描 + 建 `AttributedString`，几十 KB 没事，
    /// 但设备几百台时导出能有几百 KB —— 那时宁可出纯文本，
    /// 也不能让预览页卡住。
    private static let maxBytes = 200_000

    static func attributed(_ source: String) -> AttributedString {
        guard source.utf8.count <= maxBytes else {
            return AttributedString(source)
        }

        var result = AttributedString()
        var i = source.startIndex
        let end = source.endIndex

        func append(_ text: some StringProtocol, _ color: Color) {
            var run = AttributedString(String(text))
            run.foregroundColor = color
            result += run
        }

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
                let token = source[i..<j]

                // 后面（跳过空白）跟着冒号 → 这是键，不是值。
                var k = j
                while k < end, source[k] == " " || source[k] == "\t" {
                    k = source.index(after: k)
                }
                let isKey = k < end && source[k] == ":"
                append(token, isKey ? .purple : .red)
                i = j

            case "-", "0"..."9":
                var j = i
                while j < end, "0123456789+-.eE".contains(source[j]) {
                    j = source.index(after: j)
                }
                // 防线：万一走到这里没吃掉任何字符（理论上不会），
                // 至少保证 `i` 前进，别死循环。
                if j == i { j = source.index(after: i) }
                append(source[i..<j], .blue)
                i = j

            case "t", "f", "n":
                // true / false / null
                let rest = source[i...]
                var literal: String?
                for candidate in ["true", "false", "null"] where rest.hasPrefix(candidate) {
                    literal = candidate
                    break
                }
                if let literal {
                    append(literal, .orange)
                    i = source.index(i, offsetBy: literal.count)
                } else {
                    // 不是字面量（理论上 JSON 里不会出现，但别让扫描器卡住）。
                    append(String(ch), .primary)
                    i = source.index(after: i)
                }

            case "{", "}", "[", "]":
                append(String(ch), .secondary)
                i = source.index(after: i)

            case ":", ",":
                append(String(ch), .secondary)
                i = source.index(after: i)

            default:
                append(String(ch), .primary)
                i = source.index(after: i)
            }
        }
        return result
    }
}
