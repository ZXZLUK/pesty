import AppKit
import Combine
import SwiftUI

@MainActor
final class AgentHUDStore: ObservableObject {
    static let shared = AgentHUDStore()

    struct Card: Identifiable {
        let id: UUID
        let inputSHA256: String
        let preset: AgentCompilerPreset
        let requestedAt: Date
        var estimatedMillis: Int
        var jobID: String?
        var receiptURL: URL?
        var receipt: AgentClipboardReceipt?
        var terminalAt: Date?
        var launchFailed = false

        func presentation(at now: Date) -> AgentHUDPresentation {
            if launchFailed {
                return AgentHUDPresentation(
                    title: "启动失败",
                    detail: "\(preset.titleZH) · 编译器未启动",
                    tone: .failure,
                    isTerminal: true,
                    linger: 5
                )
            }
            return AgentHUDStateModel.presentation(
                preset: preset,
                requestedAt: receipt?.startedDate ?? requestedAt,
                estimatedMillis: estimatedMillis,
                receipt: receipt,
                now: now
            )
        }
    }

    @Published private(set) var cards: [Card] = []
    private var pollTimer: Timer?

    private init() {}

    @discardableResult
    func launchRequested(inputSHA256: String, preset: AgentCompilerPreset, at requestedAt: Date = Date()) -> UUID {
        let token = UUID()
        cards.append(Card(
            id: token,
            inputSHA256: inputSHA256,
            preset: preset,
            requestedAt: requestedAt,
            estimatedMillis: AgentETAEstimator.conservativeDefaultMillis
        ))
        ensurePolling()
        refineETA(for: token, preset: preset)
        return token
    }

    func launchFailed(_ token: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == token }) else { return }
        cards[index].launchFailed = true
        cards[index].terminalAt = Date()
    }

    private func ensurePolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    private func stopPollingIfIdle() {
        guard cards.isEmpty else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refineETA(for token: UUID, preset: AgentCompilerPreset) {
        let jobsRoot = AgentCompilerPaths.jobs
        Task { [weak self] in
            let estimate = await Task.detached(priority: .utility) {
                let receipts = Self.loadRecentReceipts(from: jobsRoot, limit: 40)
                return AgentETAEstimator.estimateMillis(from: receipts, preset: preset.rawValue)
            }.value
            guard let self,
                  let index = cards.firstIndex(where: { $0.id == token && $0.terminalAt == nil }) else { return }
            cards[index].estimatedMillis = estimate
        }
    }

    private func poll() {
        let now = Date()
        for index in cards.indices.reversed() {
            if let terminalAt = cards[index].terminalAt {
                let presentation = cards[index].presentation(at: now)
                if now.timeIntervalSince(terminalAt) >= presentation.linger {
                    cards.remove(at: index)
                }
                continue
            }

            if cards[index].launchFailed { continue }

            if let receiptURL = cards[index].receiptURL, let receipt = Self.readReceipt(receiptURL) {
                guard receipt.job_id == cards[index].jobID,
                      receipt.input_sha256 == cards[index].inputSHA256,
                      receipt.preset == cards[index].preset.rawValue else { continue }
                apply(receipt, at: index, now: now)
            } else if let candidate = findReceipt(for: cards[index]) {
                cards[index].jobID = candidate.receipt.job_id
                cards[index].receiptURL = candidate.url
                apply(candidate.receipt, at: index, now: now)
            }
        }
        stopPollingIfIdle()
    }

    private func apply(_ receipt: AgentClipboardReceipt, at index: Int, now: Date) {
        cards[index].receipt = receipt
        let presentation = cards[index].presentation(at: now)
        if presentation.isTerminal && cards[index].terminalAt == nil {
            cards[index].terminalAt = now
        }
    }

    private struct Candidate {
        let receipt: AgentClipboardReceipt
        let url: URL
    }

    private func findReceipt(for card: Card) -> Candidate? {
        if let latest = Self.readReceipt(AgentCompilerPaths.latestStatus),
           AgentReceiptMatcher.matches(latest, inputSHA256: card.inputSHA256, preset: card.preset, requestedAt: card.requestedAt),
           let candidate = Self.perJobCandidate(for: latest),
           let exact = Self.readReceipt(candidate.url), exact.job_id == latest.job_id,
           AgentReceiptMatcher.matches(exact, inputSHA256: card.inputSHA256, preset: card.preset, requestedAt: card.requestedAt) {
            return Candidate(receipt: exact, url: candidate.url)
        }

        let urls = Self.recentJobDirectories(under: AgentCompilerPaths.jobs, limit: 30)
        var best: (Candidate, TimeInterval)?
        for directory in urls {
            let receiptURL = directory.appendingPathComponent("clipboard.receipt.json")
            guard let receipt = Self.readReceipt(receiptURL),
                  receipt.job_id == directory.lastPathComponent,
                  AgentReceiptMatcher.matches(receipt, inputSHA256: card.inputSHA256, preset: card.preset, requestedAt: card.requestedAt),
                  let started = receipt.startedDate else { continue }
            let distance = abs(started.timeIntervalSince(card.requestedAt))
            let candidate = Candidate(receipt: receipt, url: receiptURL)
            if best == nil || distance < best!.1 { best = (candidate, distance) }
        }
        return best?.0
    }

    private static func perJobCandidate(for receipt: AgentClipboardReceipt) -> Candidate? {
        guard let jobID = receipt.job_id, validJobID(jobID) else { return nil }
        let url = AgentCompilerPaths.jobs
            .appendingPathComponent(jobID, isDirectory: true)
            .appendingPathComponent("clipboard.receipt.json")
        return Candidate(receipt: receipt, url: url)
    }

    nonisolated private static func validJobID(_ value: String) -> Bool {
        value.hasPrefix("clip-") && !value.contains("/") && !value.contains("..")
    }

    nonisolated private static func readReceipt(_ url: URL) -> AgentClipboardReceipt? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0, size <= 32_768,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentClipboardReceipt.self, from: data)
    }

    nonisolated private static func recentJobDirectories(under jobsRoot: URL, limit: Int) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("clip-") }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .prefix(limit)
            .map { $0 }
    }

    nonisolated private static func loadRecentReceipts(from jobsRoot: URL, limit: Int) -> [AgentClipboardReceipt] {
        recentJobDirectories(under: jobsRoot, limit: limit).compactMap { directory in
            readReceipt(directory.appendingPathComponent("clipboard.receipt.json"))
        }
    }
}

private final class AgentHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AgentHUDWindowController: NSWindowController {
    private let store: AgentHUDStore
    private var cardsSubscription: AnyCancellable?
    private static let width: CGFloat = 304
    private static let maxVisibleCards = 4

    convenience init() {
        self.init(store: .shared)
    }

    init(store: AgentHUDStore) {
        self.store = store
        let panel = AgentHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.title = "ClipBar Agent HUD"
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AgentHUDStackView(store: store))
        super.init(window: panel)

        cardsSubscription = store.$cards.sink { [weak self] cards in
            Task { @MainActor in self?.updateVisibility(cardCount: cards.count) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func reposition() {
        guard let panel = window, panel.isVisible else { return }
        position(panel, cardCount: store.cards.count)
    }

    private func updateVisibility(cardCount: Int) {
        guard let panel = window else { return }
        guard cardCount > 0 else {
            panel.orderOut(nil)
            return
        }
        position(panel, cardCount: cardCount)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func position(_ panel: NSWindow, cardCount: Int) {
        guard let screen = Self.primaryScreen() else { return }
        let visibleCount = min(cardCount, Self.maxVisibleCards)
        let overflowHeight: CGFloat = cardCount > Self.maxVisibleCards ? 24 : 0
        let height = CGFloat(visibleCount) * 68 + CGFloat(max(0, visibleCount - 1)) * 8 + 16 + overflowHeight
        let frame = NSRect(
            x: screen.visibleFrame.maxX - Self.width - 18,
            y: screen.visibleFrame.maxY - height - 18,
            width: Self.width,
            height: height
        )
        panel.setFrame(frame, display: true)
    }

    private static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main ?? NSScreen.screens.first
    }
}

private struct AgentHUDStackView: View {
    @ObservedObject var store: AgentHUDStore

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(store.cards.suffix(4))) { card in
                AgentHUDCardView(card: card)
            }
            if store.cards.count > 4 {
                Text("另有 \(store.cards.count - 4) 个编译任务")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

private struct AgentHUDCardView: View {
    let card: AgentHUDStore.Card

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = card.presentation(at: context.date)
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(toneColor(state.tone))
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(toneColor(state.tone))
                        .lineLimit(1)
                    Text(state.detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(detailColor(state.tone))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 288, height: 68, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(toneColor(state.tone).opacity(0.32), lineWidth: 1)
            }
        }
    }

    private func detailColor(_ tone: AgentHUDTone) -> Color {
        tone == .processing ? .green : .secondary
    }

    private func toneColor(_ tone: AgentHUDTone) -> Color {
        switch tone {
        case .processing, .success: return .green
        case .warning: return .yellow
        case .review: return .orange
        case .failure: return .red
        }
    }
}
