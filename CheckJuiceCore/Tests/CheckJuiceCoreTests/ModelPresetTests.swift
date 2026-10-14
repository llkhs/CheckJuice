import XCTest
@testable import CheckJuiceCore

/// 锁住「模型 = 参数」的**对外格式**。
///
/// 这套参数迟早要公开成一个 URL manifest（iOS 不允许下载并执行代码，
/// 所以能远程换的只有参数，换不了算法）。一旦发出去，字段名就是契约：
/// 改个名字，手机上拉的旧 manifest 会**静默**解成默认值——预测悄悄变了样，
/// 而没有任何报错。所以这里把键名钉在测试里，改名必炸 CI。
final class ModelPresetTests: XCTestCase {

    func testRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ModelPreset.standard)
        let decoded = try JSONDecoder().decode(ModelPreset.self, from: data)

        XCTAssertEqual(decoded, ModelPreset.standard)
        XCTAssertEqual(decoded.config, ModelConfig.standard)
    }

    func testManifestKeyNamesAreStable() throws {
        let data = try JSONEncoder().encode(ModelPreset.standard)
        let json = String(decoding: data, as: UTF8.self)

        let expected = [
            "id", "name", "summary", "config",
            "tauUser", "sigmaMin", "sigmaUnidentified",
            "sigmaPredictionCap", "beta", "z10", "minSamplesForVariance",
        ]
        for key in expected {
            XCTAssertTrue(
                json.contains("\"\(key)\""),
                "manifest 缺字段 \(key)。改名会让已发布的 manifest 静默失效。"
            )
        }
    }

    /// 默认必须走内置预设，而不是各写一份参数。
    func testStandardPresetIsWhatTheModelUsesByDefault() {
        XCTAssertEqual(ModelConfig.standard, ModelPreset.standard.config)
    }
}
