import SwiftUI
import AppKit
import CryptoKit

/// Read-only status from the compiler's bounded, body-free delivery receipt.
struct AgentClipboardReceipt: Decodable {
    let phase: String
    let delivery: String?
    let result_file: String?
    let output_sha256: String?

    var label: String {
        switch phase {
        case "compiling": return "编译中…"
        case "publishing": return "回写校验中…"
        case "needs_review": return "需要审核"
        case "failed": return "编译或回写失败"
        case "completed": return delivery == "clipboard_verified" ? "已回写剪贴板" : "已保存，未覆盖新复制"
        default: return "状态未知"
        }
    }
}

@MainActor
struct AgentStatusView: View {
    @State private var receipt: AgentClipboardReceipt?
    @State private var copyError = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects/2026/pi-podcast-compiler")
    }
    private var verifiedResultURL: URL? {
        guard let path = receipt?.result_file else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let jobs = Self.root.appendingPathComponent("var/jobs").resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(jobs), ["write.txt", "repair.txt"].contains(url.lastPathComponent) else { return nil }
        return url
    }

    var body: some View {
        Menu {
            Text(receipt?.label ?? "等待下一次复制")
            if let url = verifiedResultURL {
                Button("复制已审核结果") { copyResult(url) }
                    .disabled(receipt?.phase != "completed")
                Button("在访达中显示结果") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        } label: {
            Text(copyError ? "复制失败，请查看结果" : receipt?.label ?? "等待下一次复制")
                .font(.system(size: 9))
                .foregroundStyle(Theme.chromeTextSecondary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
        .help("点击查看或复制最近结果；模型编译期间原文仍在剪贴板")
    }

    private func refresh() {
        let path = Self.root.appendingPathComponent("var/clipboard-status.json")
        guard let size = (try? path.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= 32_768, let data = try? Data(contentsOf: path) else { return }
        receipt = try? JSONDecoder().decode(AgentClipboardReceipt.self, from: data)
    }

    private func copyResult(_ url: URL) {
        copyError = true
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= 4 * 1024 * 1024, let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8), !text.isEmpty,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == receipt?.output_sha256 else { return }
        do {
            let marker = AgentTrigger.outputMarkerURL(for: text)
            try String(Date().timeIntervalSince1970 * 1000).write(to: marker, atomically: true, encoding: .utf8)
            let pb = NSPasteboard.general
            pb.clearContents()
            guard pb.setString(text, forType: .string), pb.string(forType: .string) == text else { return }
            copyError = false
            AgentTrigger.recordEvent("manual_result_copy_verified")
        } catch { return }
    }
}
