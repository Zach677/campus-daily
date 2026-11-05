import XCTest

/// The check face is gone: no string the app shows says 再洗一次 or
/// anything of that face any more. 去核对 stays only where the 不确定 face (a settlement whose
/// outcome is unknown, kept as it is) and the home button over it use it. Scans the string
/// literals of the app, widget, shared and Core sources (comments are skipped).
final class ShowerRetiredWordsTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let retired = [
        "再洗一次",
        "这次洗澡要核对一下",
        "核对上次洗澡",
        "水控显示已经停了，但这次还没结算上",
        "上一次的记录会留着",
    ]

    /// The 不确定 face's button and the home button over an unclear authorize (kept as they are).
    static let reviewAllowed: Set<String> = [
        "App/Interface/Shower/ShowerPageView.swift|static let review = \"去核对\"",
        "Packages/Core/Sources/Core/Shower/ShowerHomeReview.swift|self.init(button: \"去核对\", caption: ShowerAuthorizeUnclearText.title(platformMessage: failure.platformMessage))",
    ]

    /// Every string literal on a source line, comments left out (`path|trimmed line` for each).
    static func literals() throws -> [(where: String, line: String, literal: String)] {
        var found: [(String, String, String)] = []
        let quoted = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        for folder in ["App", "Shared", "Widget", "Packages/Core/Sources"] {
            let base = root.appendingPathComponent(folder)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let path = String(url.path.dropFirst(root.path.count + 1))
                for raw in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("//") { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    for match in quoted.matches(in: line, range: range) {
                        found.append((path, line, String(line[Range(match.range, in: line)!])))
                    }
                }
            }
        }
        return found
    }

    func testTheSourcesAreScanned() throws {
        let all = try Self.literals()
        XCTAssertTrue(all.contains { $0.literal.contains("结束并结算") }, "the scan reaches the app's strings")
    }

    func testNoRetiredWordIsShown() throws {
        for (path, line, literal) in try Self.literals() {
            for word in Self.retired where literal.contains(word) {
                XCTFail("「\(word)」 in \(path): \(line)")
            }
            if literal.contains("去核对"), !Self.reviewAllowed.contains("\(path)|\(line)") {
                XCTFail("「去核对」 in \(path): \(line)")
            }
        }
    }
}
