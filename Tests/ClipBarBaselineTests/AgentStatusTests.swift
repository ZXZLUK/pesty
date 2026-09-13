import Testing
import Foundation
@testable import ClipBar

@Suite struct AgentStatusTests {
    private let decoder = JSONDecoder()

    private func receipt(
        phase: String,
        delivery: String? = nil,
        preset: String = "quick",
        elapsed: Double? = nil,
        started: String = "2026-09-13T08:00:00.000Z",
        verdict: String? = nil,
        inputSHA: String = "abc",
        jobID: String = "clip-job"
    ) throws -> AgentClipboardReceipt {
        var object: [String: Any] = [
            "phase": phase,
            "preset": preset,
            "started_at": started,
            "input_sha256": inputSHA,
            "job_id": jobID
        ]
        if let delivery { object["delivery"] = delivery }
        if let elapsed { object["elapsed_ms"] = elapsed }
        if let verdict { object["audit_verdict"] = verdict }
        return try decoder.decode(AgentClipboardReceipt.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func receiptsDistinguishCompilationFromDelivery() throws {
        let rows = [("compiling", "", "编译中…"), ("completed", "clipboard_verified", "已回写剪贴板"),
                    ("completed", "saved_newer_clipboard", "已保存，未覆盖新复制"), ("failed", "", "编译或回写失败"),
                    ("needs_review", "", "需要审核"), ("publishing", "", "发布校验中…")]
        for (phase, delivery, label) in rows {
            let data = try JSONSerialization.data(withJSONObject: ["phase": phase, "delivery": delivery])
            #expect(try decoder.decode(AgentClipboardReceipt.self, from: data).label == label)
        }
    }

    @Test func etaUsesRecentCompletedP75AndRoundsAwayFalsePrecision() throws {
        let receipts = try [95_880.0, 136_028.0, 138_721.0].enumerated().map { index, elapsed in
            try receipt(phase: "completed", delivery: "clipboard_verified", elapsed: elapsed,
                        started: "2026-09-13T08:0\(index):00.000Z", jobID: "job-\(index)")
        }
        #expect(AgentETAEstimator.estimateMillis(from: receipts, preset: "quick") == 140_000)
    }

    @Test func etaFallsBackConservativelyWhenSamplesAreInsufficient() throws {
        let receipts = [try receipt(phase: "completed", delivery: "clipboard_verified", elapsed: 42_000)]
        #expect(AgentETAEstimator.estimateMillis(from: receipts, preset: "quick") == 180_000)
    }

    @Test func overrunNeverPretendsCompletion() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(AgentHUDStateModel.timeText(requestedAt: start, estimatedMillis: 140_000,
                                            now: start) == "预计剩余约 02:20")
        #expect(AgentHUDStateModel.timeText(requestedAt: start, estimatedMillis: 120_000,
                                            now: start.addingTimeInterval(139)) == "仍在编译 +00:19")
    }

    @Test func receiptTerminalStatesHaveRequiredTones() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(30)
        let verified = AgentHUDStateModel.presentation(preset: .quick, requestedAt: start, estimatedMillis: 180_000,
                                                       receipt: try receipt(phase: "completed", delivery: "clipboard_verified"), now: now)
        #expect(verified.title == "✓ 编译完成")
        #expect(verified.tone == .success)
        #expect(verified.isTerminal)

        let newer = AgentHUDStateModel.presentation(preset: .quick, requestedAt: start, estimatedMillis: 180_000,
                                                    receipt: try receipt(phase: "completed", delivery: "saved_newer_clipboard"), now: now)
        #expect(newer.title == "✓ 已编译 · 未覆盖新复制")
        #expect(newer.tone == .warning)

        let review = AgentHUDStateModel.presentation(preset: .quick, requestedAt: start, estimatedMillis: 180_000,
                                                     receipt: try receipt(phase: "needs_review", verdict: "REVISE"), now: now)
        #expect(review.tone == .review)
        #expect(review.detail.contains("REVISE"))

        let failed = AgentHUDStateModel.presentation(preset: .quick, requestedAt: start, estimatedMillis: 180_000,
                                                     receipt: try receipt(phase: "failed", delivery: "not_verified"), now: now)
        #expect(failed.tone == .failure)
    }

    @Test func onlyReliableReceiptPhaseGetsSpecificStageLabel() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let pending = AgentHUDStateModel.presentation(preset: .quick, requestedAt: start, estimatedMillis: 180_000,
                                                      receipt: nil, now: start)
        #expect(pending.title == "编译中")
        let publishing = AgentHUDStateModel.presentation(preset: .quick, requestedAt: start, estimatedMillis: 180_000,
                                                         receipt: try receipt(phase: "publishing"), now: start)
        #expect(publishing.title == "发布校验中")
    }

    @Test func numericHUDShowsOnlyRoundedSecondsAndTurnsWarningAfterETA() {
        let start = Date(timeIntervalSince1970: 1_000)
        let processing = AgentHUDPresentation(title: "编译中", detail: "unused", tone: .processing, isTerminal: false, linger: 0)

        let initial = AgentHUDNumericStateModel.presentation(
            requestedAt: start, estimatedMillis: 140_000, semantic: processing, now: start
        )
        #expect(initial == AgentHUDNumericPresentation(value: 140, tone: .processing, isOverrun: false))

        let finalSecond = AgentHUDNumericStateModel.presentation(
            requestedAt: start, estimatedMillis: 140_000, semantic: processing, now: start.addingTimeInterval(139.2)
        )
        #expect(finalSecond == AgentHUDNumericPresentation(value: 1, tone: .processing, isOverrun: false))

        let overdue = AgentHUDNumericStateModel.presentation(
            requestedAt: start, estimatedMillis: 140_000, semantic: processing, now: start.addingTimeInterval(159.8)
        )
        #expect(overdue == AgentHUDNumericPresentation(value: 19, tone: .warning, isOverrun: true))
    }

    @Test func numericHUDTerminalIsReceiptToneZeroOnly() {
        let now = Date(timeIntervalSince1970: 1_000)
        for tone in [AgentHUDTone.success, .warning, .review, .failure] {
            let terminal = AgentHUDPresentation(title: "ignored", detail: "ignored", tone: tone, isTerminal: true, linger: 3)
            let numeric = AgentHUDNumericStateModel.presentation(
                requestedAt: now.addingTimeInterval(-999), estimatedMillis: 1, semantic: terminal, now: now
            )
            #expect(numeric.value == 0)
            #expect(numeric.tone == tone)
            #expect(!numeric.isOverrun)
        }
    }

    @Test func numericHUDMetricsStayMinimal() {
        #expect(AgentHUDVisualMetrics.width >= 36)
        #expect(AgentHUDVisualMetrics.width <= 50)
        #expect(AgentHUDVisualMetrics.rowHeight >= 20)
        #expect(AgentHUDVisualMetrics.rowHeight <= 28)
        #expect(AgentHUDVisualMetrics.height(for: 1) == AgentHUDVisualMetrics.rowHeight)
        #expect(AgentHUDVisualMetrics.height(for: 2) == AgentHUDVisualMetrics.rowHeight * 2 + AgentHUDVisualMetrics.rowSpacing)
    }

    @Test func receiptMatcherRejectsOldOrWrongJobs() throws {
        let request = Date(timeIntervalSince1970: 1_757_750_400) // 2025-ish exact value irrelevant; relative matching only.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let matchingStarted = formatter.string(from: request.addingTimeInterval(1))
        let oldStarted = formatter.string(from: request.addingTimeInterval(-60))
        let match = try receipt(phase: "compiling", started: matchingStarted, inputSHA: "sha-1", jobID: "new-job")
        let old = try receipt(phase: "compiling", started: oldStarted, inputSHA: "sha-1", jobID: "old-job")
        #expect(AgentReceiptMatcher.matches(match, inputSHA256: "sha-1", preset: .quick, requestedAt: request))
        #expect(!AgentReceiptMatcher.matches(old, inputSHA256: "sha-1", preset: .quick, requestedAt: request))
        #expect(!AgentReceiptMatcher.matches(match, inputSHA256: "sha-2", preset: .quick, requestedAt: request))
        #expect(!AgentReceiptMatcher.matches(match, inputSHA256: "sha-1", preset: .spoken, requestedAt: request))
    }
}
