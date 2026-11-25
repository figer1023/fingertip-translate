import Cocoa
import SQLite3
import Translation

let english = Locale.Language(identifier: "en")
let chinese = Locale.Language(identifier: "zh-Hans")
let wordPattern = #"[A-Za-z]+(?:['’\-][A-Za-z]+)*"#
let wordRegex = try! NSRegularExpression(pattern: wordPattern)

// Emoji data is immutable. SQLite serializes use of the read-only connection.
final class Lexicon: @unchecked Sendable {
    let names: [String: String]
    private var database: OpaquePointer?
    init(_ resources: URL) throws {
        names = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: resources.appendingPathComponent("emoji.json")))
        guard sqlite3_open_v2(resources.appendingPathComponent("words.sqlite").path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    deinit { sqlite3_close(database) }
    func emoji(_ text: String) -> String? {
        guard text.count == 1, text.unicodeScalars.contains(where: { $0.properties.isEmoji }) else { return nil }
        return names[text.replacingOccurrences(of: "\u{FE0F}", with: "")]
    }
    func meaning(_ text: String) -> String? {
        if let name = emoji(text) { return name }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, "select meaning from words where word=?", -1, &query, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(query) }
        return text.replacingOccurrences(of: "’", with: "'").withCString { key in
            sqlite3_bind_text(query, 1, key, -1, nil)
            guard sqlite3_step(query) == SQLITE_ROW, let result = sqlite3_column_text(query, 0) else { return nil }
            return String(cString: result)
        }
    }
    func token(_ text: String, at offset: Int) -> String? {
        let value = text as NSString
        guard offset >= 0, offset < value.length else { return nil }
        let cluster = value.substring(with: value.rangeOfComposedCharacterSequence(at: offset))
        if emoji(cluster) != nil { return cluster }
        guard let match = wordRegex.matches(in: text, range: NSRange(location: 0, length: value.length)).first(where: { NSLocationInRange(offset, $0.range) }) else { return nil }
        return value.substring(with: match.range)
    }
}

// Match the complete wording so a future change in Kiro's permission behavior
// cannot silently reuse an outdated explanation.
func knownMenuTranslation(_ text: String) -> String? {
    let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    switch normalized {
    case "Supervised Kiro pauses after each turn that edits files so you can accept or reject each change.":
        return "逐项确认\n每轮编辑文件后，Kiro 都会暂停，由你接受或拒绝每一处改动。"
    case "Accept file changes Kiro creates, edits, and deletes files without asking. It asks before it runs commands.":
        return "自动接受文件更改\nKiro 创建、编辑或删除文件时会直接执行，运行命令前会先询问你。"
    case "Approve for me For actions your rules don't cover, a model approves ones deemed safe, blocks ones deemed unsafe, and asks you when it's unsure.":
        return "替我审批\n对于规则未涵盖的操作，模型会批准它认为安全的操作，阻止它认为不安全的操作，拿不准时再问你。"
    default: return nil
    }
}
