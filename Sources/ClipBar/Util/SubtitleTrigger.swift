import AppKit
import CryptoKit
import Foundation

/// Clipboard Agent 触发器：Agent 开启时，只处理明确的字幕或长文本。
/// $1 = 捕获全文；$2 = 当前编译 preset。源材料仅作为数据传给本地编译器。
@MainActor
enum AgentTrigger {

    private static let minTimestampLines = 2
    private static let outputMarkerTTLMilliseconds: Double = 10 * 60 * 1000
    /// 时间轴行：整行只有 0:07 / 1:02:03 形式的时间戳（YouTube 转录稿特征）
    private static let timestampLine = try? NSRegularExpression(
        pattern: "(?m)^\\d{1,2}:[0-5]\\d(:[0-5]\\d)?\\s*$")

    static func looksLikeSubtitle(_ text: String) -> Bool {
        guard let ts = timestampLine else { return false }
        return ts.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) >= minTimestampLines
    }

    static func looksLikeCompilable(_ text: String, metadata: ClipboardAgentMetadata? = nil) -> Bool {
        if metadata?.requestsCompile == true {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return looksLikeSubtitle(text)
    }

    /// Content dedup must not erase an explicit producer intent. A fresh YouTube
    /// programmatic copy may be byte-identical to an older history item, but it is
    /// still a new compile request. Ordinary duplicate captures keep the old
    /// no-side-effect behavior.
    static func shouldReevaluateDuplicate(_ item: ClipItem) -> Bool {
        guard item.type == .text || item.type == .richText else { return false }
        return item.agentMetadata?.requestsCompile == true
    }

    static func outputMarkerURL(for text: String,
                                tempDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return tempDirectory.appendingPathComponent("clipbar-agent-output-\(hex).marker")
    }

    /// 编译器在 pbcopy 前写 one-shot 内容哈希 marker。命中时只消费 marker，
    /// 不再次触发 Agent，从根上阻断“Agent 输出 → 再次编译”的付费递归。
    static func consumeOutputMarkerIfPresent(_ text: String,
                                             tempDirectory: URL = FileManager.default.temporaryDirectory,
                                             nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        let url = outputMarkerURL(for: text, tempDirectory: tempDirectory)
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let created = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let age = nowMilliseconds - created
        guard age >= 0, age <= outputMarkerTTLMilliseconds else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    static func evaluate(_ item: ClipItem, in store: ClipboardStore) {
        let text = store.fullText(for: item) ?? item.text ?? ""
        if consumeOutputMarkerIfPresent(text) {
            NSLog("AgentTrigger: consumed compiler-output marker; skipping recursive trigger")
            return
        }
        guard Settings.shared.subtitleTriggerEnabled else { return }
        let code = Settings.shared.subtitleScript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        guard looksLikeCompilable(text, metadata: item.agentMetadata) else { return }
        run(code, text: text, preset: Settings.shared.agentCompilerPreset)
    }

    private static func run(_ code: String, text: String, preset: AgentCompilerPreset) {
        NSLog("AgentTrigger: firing compiler (text %d chars, preset=%@)", text.count, preset.rawValue)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // zsh -c <code> zsh <text> <preset> → $1 = 全文, $2 = preset
        task.arguments = ["-c", code, "zsh", text, preset.rawValue]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { process in
            if process.terminationStatus != 0 {
                NSLog("AgentTrigger: compiler exited with status %d", process.terminationStatus)
            }
        }
        do {
            try task.run()
        } catch {
            NSLog("AgentTrigger: compiler failed to launch: \(error)")
        }
    }
}
