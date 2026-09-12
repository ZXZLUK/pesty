import AppKit
import Foundation

/// 字幕自动处理：捕获的文本具备字幕特征（≥2 行时间轴，YouTube 转录稿
/// 复制出来的原生格式）时，自动运行用户脚本——字幕全文作为 $1 传入。
/// 主开关 + 脚本都在设置里；空脚本跳过。
@MainActor
enum SubtitleTrigger {

    private static let minTimestampLines = 2
    /// 时间轴行：整行只有 0:07 / 1:02:03 形式的时间戳（YouTube 转录稿特征）
    private static let timestampLine = try? NSRegularExpression(
        pattern: "(?m)^\\d{1,2}:[0-5]\\d(:[0-5]\\d)?\\s*$")

    static func looksLikeSubtitle(_ text: String) -> Bool {
        guard let ts = timestampLine else { return false }
        return ts.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) >= minTimestampLines
    }

    static func evaluate(_ item: ClipItem, in store: ClipboardStore) {
        guard Settings.shared.subtitleTriggerEnabled else { return }
        let code = Settings.shared.subtitleScript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        let text = store.fullText(for: item) ?? item.text ?? ""
        guard looksLikeSubtitle(text) else { return }
        run(code, text: text)
    }

    private static func run(_ code: String, text: String) {
        NSLog("SubtitleTrigger: firing user script (text %d chars)", text.count)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // zsh -c <code> zsh <text> → 脚本里 $1 = 字幕全文
        task.arguments = ["-c", code, "zsh", text]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            NSLog("SubtitleTrigger: script failed to launch: \(error)")
        }
    }
}
