import AppKit
import CryptoKit
import Foundation

/// Clipboard Agent 触发器：只处理显式路由或保留的字幕结构，不按普通文本长度触发。
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

    /// A non-adjacent recapture may carry fresh routing metadata; an adjacent
    /// duplicate remains idempotent, even when the producer attaches metadata.
    static func shouldReevaluateDuplicate(_ item: ClipItem, isHead: Bool) -> Bool {
        guard !isHead, item.type == .text || item.type == .richText else { return false }
        return item.agentMetadata?.requestsCompile == true
    }

    private static var inFlight: Set<String> = []

    /// Bounded local event evidence: never persist source text, source URLs, shell
    /// code or model credentials. This remains useful when NSLog is not retained.
    static func recordEvent(_ event: String, preset: String = "", chars: Int = 0, exit: Int32 = 0) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClipBar")
        let url = dir.appendingPathComponent("agent-events.jsonl")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue > 262_144 {
                let old = dir.appendingPathComponent("agent-events.previous.jsonl")
                try? fm.removeItem(at: old)
                try fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let data = try JSONSerialization.data(withJSONObject: ["event": event, "preset": preset, "chars": chars, "exit": exit, "time": Date().timeIntervalSince1970])
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
        } catch { NSLog("AgentTrigger: event evidence unavailable") }
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
            recordEvent("output_marker_consumed")
            NSLog("AgentTrigger: consumed compiler-output marker; skipping recursive trigger")
            return
        }
        guard Settings.shared.subtitleTriggerEnabled else {
            if item.agentMetadata?.requestsCompile == true { recordEvent("skipped_disabled") }
            return
        }
        let code = Settings.shared.subtitleScript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { recordEvent("skipped_empty_bridge"); return }
        guard looksLikeCompilable(text, metadata: item.agentMetadata) else { return }
        run(code, text: text, preset: Settings.shared.agentCompilerPreset)
    }

    private static func run(_ code: String, text: String, preset: AgentCompilerPreset) {
        let key = outputMarkerURL(for: text).lastPathComponent + ":" + preset.rawValue
        guard inFlight.insert(key).inserted else { recordEvent("skipped_in_flight", preset: preset.rawValue); return }
        recordEvent("launch_requested", preset: preset.rawValue, chars: text.count)
        NSLog("AgentTrigger: firing compiler (text %d chars, preset=%@)", text.count, preset.rawValue)
        let task = Process()
        var env = ProcessInfo.processInfo.environment
        for name in ["LANG", "LC_CTYPE", "LC_ALL"] { env[name] = "en_US.UTF-8" }
        task.environment = env
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // zsh -c <code> zsh <text> <preset> → $1 = 全文, $2 = preset
        task.arguments = ["-c", code, "zsh", text, preset.rawValue]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in
                inFlight.remove(key)
                recordEvent("process_exited", preset: preset.rawValue, exit: status)
            }
        }
        do {
            try task.run()
            recordEvent("process_started", preset: preset.rawValue)
        } catch {
            inFlight.remove(key)
            recordEvent("launch_failed", preset: preset.rawValue)
            NSLog("AgentTrigger: compiler failed to launch: \(error)")
        }
    }
}
