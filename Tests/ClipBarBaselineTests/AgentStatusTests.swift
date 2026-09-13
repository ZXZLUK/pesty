import Testing
import Foundation
@testable import ClipBar

@Suite struct AgentStatusTests {
    @Test func receiptsDistinguishCompilationFromDelivery() throws {
        let decoder = JSONDecoder()
        let rows = [("compiling", "", "编译中…"), ("completed", "clipboard_verified", "已回写剪贴板"),
                    ("completed", "saved_newer_clipboard", "已保存，未覆盖新复制"), ("failed", "", "编译或回写失败"),
                    ("needs_review", "", "需要审核")]
        for (phase, delivery, label) in rows {
            let data = try JSONSerialization.data(withJSONObject: ["phase": phase, "delivery": delivery])
            #expect(try decoder.decode(AgentClipboardReceipt.self, from: data).label == label)
        }
    }
}
