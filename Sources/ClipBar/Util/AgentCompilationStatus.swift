import Foundation

struct AgentClipboardReceipt: Decodable, Equatable {
    let schema_version: Int?
    let job_id: String?
    let job_dir: String?
    let preset: String?
    let started_at: String?
    let updated_at: String?
    let input_sha256: String?
    let input_chars: Int?
    let elapsed_ms: Double?
    let phase: String
    let delivery: String?
    let audit_verdict: String?
    let error_code: String?
    let result_file: String?
    let output_sha256: String?

    var label: String {
        if phase == "failed" || delivery == "not_verified" { return "编译或回写失败" }
        switch phase {
        case "map": return "内容映射中…"
        case "write": return "成稿中…"
        case "audit": return "审核中…"
        case "compiling": return "编译中…"
        case "publishing": return "发布校验中…"
        case "needs_review": return "需要审核"
        case "completed":
            if delivery == "clipboard_verified" { return "已回写剪贴板" }
            if delivery == "saved_newer_clipboard" { return "已保存，未覆盖新复制" }
            return "交付状态待确认"
        default: return "状态未知"
        }
    }

    var startedDate: Date? {
        guard let started_at else { return nil }
        return AgentReceiptDateParser.date(from: started_at)
    }
}

enum AgentCompilerPaths {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("projects/2026/pi-podcast-compiler")
    }

    static var jobs: URL { root.appendingPathComponent("var/jobs", isDirectory: true) }
    static var latestStatus: URL { root.appendingPathComponent("var/clipboard-status.json") }
}

enum AgentReceiptDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from value: String) -> Date? {
        fractional.date(from: value) ?? plain.date(from: value)
    }
}

enum AgentETAEstimator {
    static let conservativeDefaultMillis = 180_000
    static let minimumSamples = 3
    static let maximumSamples = 9

    static func estimateMillis(
        from receipts: [AgentClipboardReceipt],
        preset: String,
        defaultMillis: Int = conservativeDefaultMillis
    ) -> Int {
        let eligible = receipts
            .filter {
                $0.phase == "completed" &&
                $0.preset == preset &&
                ($0.elapsed_ms ?? 0) >= 10_000 &&
                ($0.elapsed_ms ?? 0) <= 30 * 60 * 1000
            }
            .sorted { ($0.startedDate ?? .distantPast) > ($1.startedDate ?? .distantPast) }
            .prefix(maximumSamples)

        guard eligible.count >= minimumSamples else { return defaultMillis }
        let values = eligible.compactMap { $0.elapsed_ms }.sorted()
        guard !values.isEmpty else { return defaultMillis }

        // Nearest-rank P75 is deliberately conservative and less sensitive than a mean.
        let rank = max(1, Int(ceil(0.75 * Double(values.count))))
        let p75 = Int(values[min(values.count - 1, rank - 1)])
        // The estimate is empirical, not a promise. Round to 10 s to avoid false precision.
        return max(10_000, ((p75 + 5_000) / 10_000) * 10_000)
    }
}

enum AgentHUDTone: Equatable {
    case processing
    case success
    case warning
    case review
    case failure
}

struct AgentHUDPresentation: Equatable {
    let title: String
    let detail: String
    let tone: AgentHUDTone
    let isTerminal: Bool
    let linger: TimeInterval
}

enum AgentHUDStateModel {
    static func presentation(
        preset: AgentCompilerPreset,
        requestedAt: Date,
        estimatedMillis: Int,
        receipt: AgentClipboardReceipt?,
        now: Date
    ) -> AgentHUDPresentation {
        let presetLabel = preset.titleZH

        if let receipt {
            if receipt.phase == "failed" || receipt.delivery == "not_verified" {
                return AgentHUDPresentation(
                    title: "编译失败",
                    detail: "\(presetLabel) · 未验证交付",
                    tone: .failure,
                    isTerminal: true,
                    linger: 6
                )
            }
            if receipt.phase == "needs_review" || receipt.audit_verdict?.uppercased() == "REVISE" {
                let verdict = receipt.audit_verdict?.uppercased() == "REVISE" ? " · REVISE" : ""
                return AgentHUDPresentation(
                    title: "需要审核",
                    detail: "\(presetLabel)\(verdict)",
                    tone: .review,
                    isTerminal: true,
                    linger: 6
                )
            }
            if receipt.phase == "completed", receipt.delivery == "clipboard_verified" {
                return AgentHUDPresentation(
                    title: "✓ 编译完成",
                    detail: "\(presetLabel) · 已回写剪贴板",
                    tone: .success,
                    isTerminal: true,
                    linger: 2.5
                )
            }
            if receipt.phase == "completed", receipt.delivery == "saved_newer_clipboard" {
                return AgentHUDPresentation(
                    title: "✓ 已编译 · 未覆盖新复制",
                    detail: presetLabel,
                    tone: .warning,
                    isTerminal: true,
                    linger: 4
                )
            }
            if receipt.phase == "completed" {
                return AgentHUDPresentation(
                    title: "交付状态待确认",
                    detail: presetLabel,
                    tone: .review,
                    isTerminal: true,
                    linger: 6
                )
            }
        }

        let phaseTitle: String
        switch receipt?.phase {
        case "map": phaseTitle = "内容映射中"
        case "write": phaseTitle = "成稿中"
        case "audit": phaseTitle = "审核中"
        case "publishing": phaseTitle = "发布校验中"
        default: phaseTitle = "编译中"
        }

        return AgentHUDPresentation(
            title: phaseTitle,
            detail: "\(presetLabel) · \(timeText(requestedAt: requestedAt, estimatedMillis: estimatedMillis, now: now))",
            tone: .processing,
            isTerminal: false,
            linger: 0
        )
    }

    static func timeText(requestedAt: Date, estimatedMillis: Int, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(requestedAt))
        let estimate = max(1, Double(estimatedMillis) / 1000)
        if elapsed < estimate {
            let remaining = estimate - elapsed
            let rounded = max(10, Int(ceil(remaining / 10)) * 10)
            return "预计剩余约 \(clock(rounded))"
        }
        return "仍在编译 +\(clock(Int(elapsed - estimate)))"
    }

    private static func clock(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

enum AgentReceiptMatcher {
    static func matches(
        _ receipt: AgentClipboardReceipt,
        inputSHA256: String,
        preset: AgentCompilerPreset,
        requestedAt: Date,
        earlyTolerance: TimeInterval = 3,
        maximumStartDelay: TimeInterval = 30
    ) -> Bool {
        guard let jobID = receipt.job_id, !jobID.isEmpty,
              receipt.input_sha256 == inputSHA256,
              receipt.preset == preset.rawValue,
              let started = receipt.startedDate else { return false }
        let delta = started.timeIntervalSince(requestedAt)
        return delta >= -earlyTolerance && delta <= maximumStartDelay
    }
}
