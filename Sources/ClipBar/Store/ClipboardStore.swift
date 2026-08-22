import AppKit
import Observation
import CryptoKit

extension Notification.Name {
    static let clipbarStoreDidSave = Notification.Name("ClipBarStoreDidSave")
}

enum BarSource: Equatable {
    case history
    case pinboard(UUID)
}

@Observable
@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var history: [ClipItem] = []
    private(set) var pinboards: [Pinboard] = []

    var source: BarSource = .history {
        didSet { if source != oldValue { clearMultiSelection() } }
    }
    var searchText: String = "" {
        didSet { if searchText != oldValue { clearMultiSelection() } }
    }
    var selectedID: UUID?
    private(set) var multiSelectedIDs: Set<UUID> = []
    private var selectionAnchorID: UUID?

    /// Bumped every time the bar is about to present. The hosting view is
    /// built once and cached, so the strip keeps its scroll offset across
    /// hide/show; selection alone cannot reset it because the newest clip is
    /// usually already selected and `onChange` never fires for equal values.
    private(set) var barPresentationToken = 0

    var historyLimit: Int {
        get { Settings.shared.historyLimit }
        set { Settings.shared.historyLimit = newValue; trimHistory() }
    }

    private var db: SQLiteStore?
    private var legacyStoreURL: URL
    private var imagesDir: URL
    private var baseDir: URL
    private var saveWorkItem: DispatchWorkItem?
    private var pendingBlobDeletes: [UUID] = []

    /// Short-lived record of the last deletion so ⌘Z can bring it back.
    /// Only user deletions from the bar land here (not retention pruning).
    private var lastDeletion: [(container: String, item: ClipItem, index: Int)]?
    private var deletionExpiredAt = Date.distantPast
    private var deletionExpiryWork: DispatchWorkItem?
    private(set) var deletionHint: String?

    /// Bumped on every content mutation so the search index cache can be
    /// validated cheaply instead of re-derived per keystroke.
    private var dataVersion = 0
    private var searchIndex: [UUID: (version: Int, text: String, pinyin: String)] = [:]

    private let imageCache = NSCache<NSString, NSImage>()

    /// Text/RTF payloads above this size are kept in memory only as a preview
    /// after the next successful flush; full content is re-read from the
    /// database on paste/edit. Keeps memory independent of clip size.
    static let memoryPreviewLimit = 64_000
    private let saveQueue = DispatchQueue(label: "clipbar.store.save", qos: .utility)
    private var backupTimer: Timer?

    /// Ephemeral per-presentation type filter for the bar (nil = all).
    var typeFilter: ClipType?

    static var localBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipBar", isDirectory: true)
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static var iCloudBase: URL? {
        guard !isSandboxed else { return nil }
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: p.path) else { return nil }
        return p.appendingPathComponent("ClipBar", isDirectory: true)
    }

    var iCloudAvailable: Bool { ClipboardStore.iCloudBase != nil }

    private init() {
        let base = ClipboardStore.localBase
        baseDir = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        legacyStoreURL = base.appendingPathComponent("store.json")
        imageCache.countLimit = 200
        prepareDirectories()
        db = SQLiteStore(directory: base)
        load()
        performStorageHygiene()
        performDailyBackupIfNeeded()
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.performDailyBackupIfNeeded() }
        }
        RunLoop.main.add(t, forMode: .common)
        backupTimer = t
    }

    /// Settings-facing backup surface.
    @discardableResult
    func runBackupNow() -> Bool {
        guard let db else { return false }
        let dir = baseDir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let target = dir.appendingPathComponent("history-\(stamp).db")
        // 同日重跑：先移除旧快照再生成，保持一天一份、内容最新。
        try? FileManager.default.removeItem(at: target)
        guard db.backup(to: target) else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        pruneBackups(dir: dir)
        return true
    }

    var lastBackupDate: Date? {
        let dir = baseDir.appendingPathComponent("backups", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }

    var backupsDirectory: URL {
        baseDir.appendingPathComponent("backups", isDirectory: true)
    }

    private func pruneBackups(dir: URL) {
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
           files.count > 7 {
            for name in files.prefix(files.count - 7) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// Startup housekeeping: drop blob files orphaned by crashes, and cap the
    /// quarantine/migration files so they cannot accumulate forever.
    private func performStorageHygiene() {
        let orphans = db?.deleteUnreferencedBlobs() ?? 0
        if orphans > 0 { NSLog("ClipBar: removed \(orphans) orphan blob file(s)") }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: baseDir.path) else { return }
        let prefixes = ["store.json.corrupt-", "store.json.migrated-", "history.db.corrupt-"]
        for prefix in prefixes {
            let sorted = files.filter { $0.hasPrefix(prefix) }.sorted()
            if sorted.count > 5 {
                for name in sorted.prefix(sorted.count - 5) {
                    try? fm.removeItem(at: baseDir.appendingPathComponent(name))
                }
            }
        }
    }

    /// One snapshot per day into backups/, newest 7 kept (VACUUM INTO gives a
    /// consistent online copy without stopping the app).
    private func performDailyBackupIfNeeded() {
        guard let db else { return }
        let dir = baseDir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let target = dir.appendingPathComponent("history-\(stamp).db")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        guard db.backup(to: target) else {
            NSLog("ClipBar: daily backup failed"); return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        pruneBackups(dir: dir)
    }

    private func prepareDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
    }

    var visibleItems: [ClipItem] {
        let base: [ClipItem]
        switch source {
        case .history:
            base = history
        case .pinboard(let id):
            base = pinboards.first(where: { $0.id == id })?.items ?? []
        }
        let filtered: [ClipItem]
        if let f = typeFilter { filtered = base.filter { $0.type == f } }
        else { filtered = base }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return filtered }
        let pinyinQuery = Pinyin.isPinyinQuery(q)
        return filtered.filter { item in
            let idx = cachedIndex(for: item)
            if idx.text.contains(q) { return true }
            return pinyinQuery && idx.pinyin.contains(q)
        }
    }

    private func cachedIndex(for item: ClipItem) -> (text: String, pinyin: String) {
        if let hit = searchIndex[item.id], hit.version == dataVersion {
            return (hit.text, hit.pinyin)
        }
        let text = item.searchableText
        let pinyin = Pinyin.index(for: text)
        searchIndex[item.id] = (dataVersion, text, pinyin)
        return (text, pinyin)
    }

    var selectedItem: ClipItem? {
        guard let id = selectedID else { return nil }
        return visibleItems.first(where: { $0.id == id })
    }

    func addCaptured(_ item: ClipItem) {
        if let idx = history.firstIndex(where: { $0.sameContent(as: item) }) {
            if item.imageFileName != history[idx].imageFileName { deleteImageFile(item) }
            var existing = history.remove(at: idx)
            existing.createdAt = item.createdAt
            history.insert(existing, at: 0)
            if source == .history && searchText.isEmpty && multiSelectedIDs.isEmpty {
                selectedID = existing.id
                selectionAnchorID = existing.id
            }
            scheduleSave()
            return
        }
        history.insert(item, at: 0)
        trimHistory()
        if source == .history && searchText.isEmpty && multiSelectedIDs.isEmpty {
            selectedID = item.id
            selectionAnchorID = item.id
        }
        scheduleSave()
    }

    func applyRetentionPolicy() { trimHistory(); scheduleSave() }

    func retentionRemovalCount(mode: HistoryRetentionMode, limit: Int, days: Int) -> Int {
        switch mode {
        case .itemCount:
            return max(0, history.count - max(20, limit))
        case .timeInterval:
            // Time-based retention has no item-count ceiling: the user asked for
            // unlimited history age-pruned on a cycle (e.g. weekly).
            let cutoff = Self.retentionCutoff(daysAgo: days)
            return history.filter { $0.createdAt < cutoff }.count
        }
    }

    private static func retentionCutoff(daysAgo days: Int) -> Date {
        Date().addingTimeInterval(-TimeInterval(max(1, days)) * 86_400)
    }

    private(set) var retentionPrunedRecordNames: Set<String> = []

    func isRetentionPruned(_ recordName: String) -> Bool {
        retentionPrunedRecordNames.contains(recordName)
    }

    private func trimHistory() {
        var removed: [ClipItem] = []
        switch Settings.shared.historyRetentionMode {
        case .itemCount:
            if history.count > historyLimit {
                removed = Array(history[historyLimit...])
                history.removeLast(history.count - historyLimit)
            }
        case .timeInterval:
            // No count ceiling: age-based retention only (user-facing promise
            // is "unlimited history, pruned by age").
            let cutoff = Self.retentionCutoff(daysAgo: Settings.shared.historyRetentionDays)
            let old = history.filter { $0.createdAt < cutoff }
            if !old.isEmpty {
                removed += old
                history.removeAll { $0.createdAt < cutoff }
            }
        }
        guard !removed.isEmpty else { return }
        for item in removed { deleteImageFile(item) }
        markRetentionPruned(removed)
        if let sel = selectedID, removed.contains(where: { $0.id == sel }) { selectFirst() }
        reconcileMultiSelection()
    }

    private func markRetentionPruned(_ items: [ClipItem]) {
        let names = items.map { $0.id.uuidString }
        retentionPrunedRecordNames.formUnion(names)
        #if MAS
        CloudSyncService.shared.retainRemoteRecords(named: names)
        #endif
    }

    /// Deletes a clip from the collection currently on screen only. A Pinboard
    /// is an independently saved collection: deleting a card from history must
    /// not erase saved copies, and deleting a pinboard copy must not touch
    /// history or other pinboards, even for legacy clips that share an id.
    /// Deleting exactly what was removed also closes an image-file leak: the
    /// old cross-container removal deleted entries under two file names but
    /// cleaned up only one of them.
    func delete(_ item: ClipItem) { delete(items: [item]) }

    func delete(items: [ClipItem]) {
        let ids = Set(items.map(\.id))
        guard !ids.isEmpty else { return }
        recordForUndo(ids: ids)
        // Captured before removal so repeated deletes walk down the list
        // instead of snapping back to the newest clip every time.
        let deletedIndex = visibleItems.firstIndex(where: { ids.contains($0.id) })
        let selectionDeleted = selectedID.map { ids.contains($0) } ?? false
        let removed: [ClipItem]
        switch source {
        case .history:
            removed = history.filter { ids.contains($0.id) }
            history.removeAll { ids.contains($0.id) }
        case .pinboard(let boardID):
            guard let boardIndex = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
            removed = pinboards[boardIndex].items.filter { ids.contains($0.id) }
            pinboards[boardIndex].items.removeAll { ids.contains($0.id) }
        }
        for entry in removed { deleteImageFile(entry) }
        multiSelectedIDs.subtract(ids)
        if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
        if selectionDeleted {
            let remaining = visibleItems
            if let index = deletedIndex, !remaining.isEmpty {
                selectedID = remaining[min(index, remaining.count - 1)].id
            } else {
                selectFirst()
            }
            selectionAnchorID = selectedID
        }
        reconcileMultiSelection()
        scheduleSave()
    }

    /// Remembers positions so `undoDelete()` can restore them verbatim.
    /// Note: an image clip's PNG may already be gone by undo time; the paste
    /// path fails gracefully in that case (KI-004 transaction).
    private func recordForUndo(ids: Set<UUID>) {
        var recs: [(String, ClipItem, Int)] = []
        if case .history = source {
            for (i, item) in history.enumerated() where ids.contains(item.id) {
                recs.append(("history", item, i))
            }
        } else if case .pinboard(let boardID) = source {
            if let board = pinboards.first(where: { $0.id == boardID }) {
                for (i, item) in board.items.enumerated() where ids.contains(item.id) {
                    recs.append((boardID.uuidString, item, i))
                }
            }
        }
        guard !recs.isEmpty else { return }
        lastDeletion = recs
        deletionExpiredAt = Date().addingTimeInterval(10)
        deletionHint = L10n.t("Deleted \(recs.count) · ⌘Z to undo", "已删除 \(recs.count) 条 · ⌘Z 撤销")
        deletionExpiryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.lastDeletion = nil
            self?.deletionHint = nil
        }
        deletionExpiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    @discardableResult
    func undoDelete() -> Bool {
        guard let recs = lastDeletion, Date() < deletionExpiredAt else { return false }
        lastDeletion = nil
        deletionHint = nil
        deletionExpiryWork?.cancel()
        // 从后往前按原索引插回，保证前面的索引不被自己的插入顶偏。
        for rec in recs.reversed() {
            if rec.container == "history" {
                history.insert(rec.item, at: min(rec.index, history.count))
            } else if let id = UUID(uuidString: rec.container),
                      let board = pinboards.firstIndex(where: { $0.id == id }) {
                pinboards[board].items.insert(rec.item, at: min(rec.index, pinboards[board].items.count))
            }
        }
        retentionPrunedRecordNames.subtract(recs.map { $0.item.id.uuidString })
        if selectedItem == nil { selectFirst() }
        scheduleSave()
        return true
    }

    func clearHistory() {
        let old = history
        history.removeAll()
        selectedID = nil
        for item in old { deleteImageFile(item) }
        reconcileMultiSelection()
        scheduleSave()
    }

    @discardableResult
    func addPinboard(name: String, colorHex: String = "#5B8DEF") -> Pinboard {
        let b = Pinboard(name: name, colorHex: colorHex)
        pinboards.append(b)
        scheduleSave()
        return b
    }

    func renamePinboard(_ id: UUID, to name: String) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[i].name = name
        scheduleSave()
    }

    func deletePinboard(_ id: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        if case .pinboard(let cur) = source, cur == id { source = .history }
        let removedItems = pinboards[i].items
        pinboards.remove(at: i)
        for item in removedItems { deleteImageFile(item) }
        reconcileMultiSelection()
        scheduleSave()
    }

    func saveToPinboard(_ item: ClipItem, boardID: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
        if pinboards[i].items.contains(where: { $0.sameContent(as: item) }) { return }
        // Pinboard copies mint their own UUID (one sync record per container).
        var copy = ClipItem(
            type: item.type,
            text: item.text,
            rtfData: item.rtfData,
            imageFileName: item.imageFileName,
            imageHash: item.imageHash,
            fileURLs: item.fileURLs,
            colorHex: item.colorHex,
            sourceBundleID: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            customTitle: item.customTitle,
            createdAt: item.createdAt)
        // Hash-named image files are shared with history (storeImageData
        // deduplicates by content); no physical copy per pinboard entry.
        pinboards[i].items.insert(copy, at: 0)
        scheduleSave()
    }

    /// MRU: using a clip (paste or copy) moves it to the head of history with
    /// a fresh timestamp, so the next ⌘⇧V starts where your hand just was.
    func promoteToHead(_ item: ClipItem) {
        guard let idx = history.firstIndex(where: { $0.id == item.id }), idx != 0 else { return }
        var promoted = history.remove(at: idx)
        promoted.createdAt = Date()
        history.insert(promoted, at: 0)
        scheduleSave()
    }

    func item(withID id: UUID) -> ClipItem? {
        if let item = history.first(where: { $0.id == id }) { return item }
        return pinboards.lazy.flatMap(\.items).first(where: { $0.id == id })
    }

    @discardableResult
    func updateTextContent(_ text: String, richTextData: Data? = nil, for item: ClipItem) -> Bool {
        guard [.text, .richText, .link].contains(item.type),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let type: ClipType = richTextData != nil ? .richText : (isWebLink(text) ? .link : .text)
        return updateContent(of: item) { existing in
            var updated = existing
            updated.type = type
            updated.text = text
            updated.rtfData = richTextData
            updated.colorHex = nil
            return updated
        }
    }

    @discardableResult
    func updateColorContent(_ hex: String, for item: ClipItem) -> Bool {
        guard item.type == .color, let color = NSColor(hex: hex) else { return false }
        let normalized = color.hexString
        return updateContent(of: item) { existing in
            var updated = existing
            updated.type = .color
            updated.text = nil
            updated.rtfData = nil
            updated.colorHex = normalized
            return updated
        }
    }

    private func updateContent(of item: ClipItem, transform: (ClipItem) -> ClipItem) -> Bool {
        var changed = false
        let now = Date()

        if let i = history.firstIndex(where: { $0.id == item.id }) {
            var updated = transform(history[i])
            if updated != history[i] {
                updated.createdAt = now
                history.remove(at: i)
                removeContentDuplicates(of: updated, in: &history)
                history.insert(updated, at: 0)
                changed = true
            }
        }

        for b in pinboards.indices {
            guard let i = pinboards[b].items.firstIndex(where: { $0.id == item.id }) else { continue }
            var updated = transform(pinboards[b].items[i])
            if updated != pinboards[b].items[i] {
                updated.createdAt = now
                pinboards[b].items[i] = updated
                removeContentDuplicates(of: updated, in: &pinboards[b].items)
                changed = true
            }
        }

        guard changed else { return false }
        retentionPrunedRecordNames.remove(item.id.uuidString)
        if selectedItem == nil { selectFirst() }
        reconcileMultiSelection()
        scheduleSave()
        return true
    }

    private func removeContentDuplicates(of item: ClipItem, in items: inout [ClipItem]) {
        let key = item.contentKey
        let duplicates = items.filter { $0.id != item.id && $0.contentKey == key }
        guard !duplicates.isEmpty else { return }
        items.removeAll { $0.id != item.id && $0.contentKey == key }
        for duplicate in duplicates { deleteImageFile(duplicate) }
    }

    private func isWebLink(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(" "), !value.contains("\n"),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    func setTitle(_ title: String, for item: ClipItem) {
        if let i = history.firstIndex(where: { $0.id == item.id }) { history[i].customTitle = title }
        for b in pinboards.indices {
            if let i = pinboards[b].items.firstIndex(where: { $0.id == item.id }) {
                pinboards[b].items[i].customTitle = title
            }
        }
        scheduleSave()
    }

    func selectFirst() { selectedID = visibleItems.first?.id }

    var effectiveSelectionIDs: Set<UUID> {
        if !multiSelectedIDs.isEmpty { return multiSelectedIDs }
        return selectedID.map { [$0] } ?? []
    }

    func isSelected(_ id: UUID) -> Bool {
        if multiSelectedIDs.isEmpty { return selectedID == id }
        return multiSelectedIDs.contains(id)
    }

    func select(_ id: UUID) {
        selectedID = id
        selectionAnchorID = id
        multiSelectedIDs = []
    }

    func toggleSelection(_ id: UUID) {
        guard visibleItems.contains(where: { $0.id == id }) else { return }
        if multiSelectedIDs.isEmpty, let sel = selectedID, sel != id,
           visibleItems.contains(where: { $0.id == sel }) {
            multiSelectedIDs = [sel]
        }
        if multiSelectedIDs.contains(id) {
            multiSelectedIDs.remove(id)
            if selectedID == id { selectedID = multiSelectedIDs.first ?? visibleItems.first?.id }
            if selectionAnchorID == id { selectionAnchorID = selectedID }
            if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
        } else {
            multiSelectedIDs.insert(id)
            selectedID = id
            if selectionAnchorID == nil { selectionAnchorID = id }
            if multiSelectedIDs.count == 1 { multiSelectedIDs = [] }
        }
    }

    func extendSelection(to id: UUID) {
        let items = visibleItems
        guard let targetIndex = items.firstIndex(where: { $0.id == id }) else { return }
        guard let anchor = selectionAnchorID ?? selectedID,
              let anchorIndex = items.firstIndex(where: { $0.id == anchor }) else {
            select(id)
            return
        }
        let range = items[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)]
        multiSelectedIDs = Set(range.map(\.id))
        selectedID = id
        selectionAnchorID = anchor
        if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
    }

    func clearMultiSelection() {
        multiSelectedIDs = []
        selectionAnchorID = selectedID
    }

    private func reconcileMultiSelection() {
        guard !multiSelectedIDs.isEmpty else { return }
        let visible = Set(visibleItems.map(\.id))
        multiSelectedIDs.formIntersection(visible)
        if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
        if let anchor = selectionAnchorID, !visible.contains(anchor) {
            selectionAnchorID = selectedID
        }
        if let sel = selectedID, !visible.contains(sel) {
            selectedID = multiSelectedIDs.first ?? visibleItems.first?.id
        }
    }

    func prepareForBarPresentation() {
        typeFilter = nil
        applyRetentionPolicy()
        clearMultiSelection()
        barPresentationToken &+= 1
        selectFirst()
    }

    func moveSelection(by delta: Int) {
        clearMultiSelection()
        let items = visibleItems
        guard !items.isEmpty else { return }
        guard let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) else {
            selectedID = items.first?.id; return
        }
        let next = max(0, min(items.count - 1, idx + delta))
        selectedID = items[next].id
        selectionAnchorID = selectedID
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesDir.appendingPathComponent(name)
    }

    func loadImage(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        if let cached = imageCache.object(forKey: name as NSString) { return cached }
        guard let url = imageURL(for: item),
              let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: name as NSString)
        return image
    }

    /// Files are named by content SHA-256, so identical screenshots stored in
    /// history and pinboards share one file instead of duplicating on disk.
    func storeImageData(_ data: Data) -> String? {
        let digest = CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "\(digest).png"
        let url = imagesDir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return name }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return name
        } catch { return nil }
    }

    private func deleteImageFile(_ item: ClipItem) {
        // Large-payload blob files (oversized text/RTF) are released together
        // with the clip's image assets when the clip leaves every container.
        pendingBlobDeletes.append(item.id)
        guard let name = item.imageFileName else { return }
        let stillUsed = history.contains { $0.imageFileName == name }
            || pinboards.contains { $0.items.contains { $0.imageFileName == name } }
        if stillUsed { return }
        imageCache.removeObject(forKey: name as NSString)
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    private struct LegacySnapshot: Codable {
        var history: [ClipItem]
        var pinboards: [Pinboard]
    }

    private func load() {
        if let db {
            let snap = db.load()
            history = snap.history
            pinboards = snap.pinboards
            selectFirst()
            migrateLegacyJSONIfNeeded()
            trimMemoryPreviews()
            return
        }
        // Database could not be opened even after quarantine: fall back to the
        // legacy JSON if present (read-only session; saves will keep failing loud).
        guard let data = try? Data(contentsOf: legacyStoreURL),
              let snap = try? JSONDecoder().decode(LegacySnapshot.self, from: data) else { return }
        history = snap.history
        pinboards = snap.pinboards
        selectFirst()
    }

    /// One-time import of the pre-SQLite store.json, then the file is renamed
    /// so it is never re-imported. Data always stays local.
    private func migrateLegacyJSONIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyStoreURL.path) else { return }
        if history.isEmpty && pinboards.isEmpty,
           let data = try? Data(contentsOf: legacyStoreURL),
           let snap = try? JSONDecoder().decode(LegacySnapshot.self, from: data) {
            history = snap.history
            pinboards = snap.pinboards
            selectFirst()
            saveNow()
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.moveItem(
            at: legacyStoreURL, to: legacyStoreURL.appendingPathExtension("migrated-\(stamp)"))
    }

    private func scheduleSave() {
        dataVersion &+= 1
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow(wait: Bool = false) {
        guard let db else {
            NSLog("ClipBar: no database handle; skipping save")
            return
        }
        var containers: Set<String> = ["history"]
        for board in pinboards { containers.insert(board.id.uuidString) }
        let deletedBlobs = pendingBlobDeletes
        pendingBlobDeletes.removeAll(keepingCapacity: true)
        let historyCopy = history
        let boardsCopy = pinboards
        let apply: @Sendable () -> Void = { [weak self] in
            guard db.flush(history: historyCopy, pinboards: boardsCopy,
                           dirtyContainers: containers, deletedBlobIDs: deletedBlobs) else {
                // KNOWN_ISSUES KI-005: a failed write must not be reported as saved.
                NSLog("ClipBar: database flush failed")
                DispatchQueue.main.async { self?.pendingBlobDeletes = deletedBlobs + (self?.pendingBlobDeletes ?? []) }
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.trimMemoryPreviews()
                NotificationCenter.default.post(name: .clipbarStoreDidSave, object: nil)
            }
        }
        if wait { saveQueue.sync(execute: apply) } else { saveQueue.async(execute: apply) }
    }

    /// After the database holds the full payload, shrink the in-memory copies
    /// to previews. Runs on the main thread right after a successful flush.
    private func trimMemoryPreviews() {
        let limit = Self.memoryPreviewLimit
        var trimmed = false
        // Idempotent by size (not flag): a reload may bring full text back
        // with textTruncated already set, and it still needs trimming.
        func trim(_ item: inout ClipItem) {
            if let t = item.text, t.utf8.count > limit {
                item.text = String(t.prefix(limit))
                item.textTruncated = true
                trimmed = true
            }
            if let r = item.rtfData, r.count > limit {
                item.rtfData = nil
                item.textTruncated = true
                trimmed = true
            }
        }
        for i in history.indices { trim(&history[i]) }
        for b in pinboards.indices {
            for j in pinboards[b].items.indices { trim(&pinboards[b].items[j]) }
        }
        if trimmed { dataVersion &+= 1 }
    }

    /// Full text/RTF for paste & edit paths (reads the database when the
    /// in-memory item carries only a preview).
    func fullText(for item: ClipItem) -> String? {
        guard item.textTruncated else { return item.text }
        return db?.loadFullPayload(id: item.id).text ?? item.text
    }

    func fullRTF(for item: ClipItem) -> Data? {
        guard item.textTruncated else { return item.rtfData }
        return db?.loadFullPayload(id: item.id).rtfData ?? item.rtfData
    }

    // MARK: - Remote (CloudKit) apply

    /// Applies decoded CloudKit clips. Dedupe by contentKey keeps the newer
    /// createdAt; insertion stays newest-first. Callers update their own
    /// last-synced bookkeeping so these changes do not loop back into sync.
    func applyRemote(clips: [(ClipItem, container: String, imageSourceURL: URL?)]) {
        guard !clips.isEmpty else { return }
        for entry in clips {
            let item = entry.0
            // The per-app exclusion list is local to each Mac and is not synced, so a
            // clip from an ignored app copied on another device would otherwise arrive
            // here and land in history anyway. A privacy filter that leaks across
            // devices is not a privacy filter.
            guard !Settings.shared.isIgnoringSourceApp(item.sourceBundleID) else { continue }
            if let src = entry.imageSourceURL, let name = item.imageFileName {
                let dst = imagesDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
            }
            if entry.container == "history" {
                applyRemoteToHistory(item)
            } else if let boardID = UUID(uuidString: entry.container) {
                applyRemoteToPinboard(item, boardID: boardID)
            }
        }
        trimHistory()
        if selectedID == nil { selectFirst() }
        reconcileMultiSelection()
        scheduleSave()
    }

    func applyRemoteDeletes(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let removedHistory = history.filter { set.contains($0.id) }
        history.removeAll { set.contains($0.id) }
        var removedPinned: [ClipItem] = []
        for i in pinboards.indices {
            removedPinned += pinboards[i].items.filter { set.contains($0.id) }
            pinboards[i].items.removeAll { set.contains($0.id) }
        }
        let removedBoards = pinboards.filter { set.contains($0.id) }
        pinboards.removeAll { set.contains($0.id) }
        if case .pinboard(let cur) = source, set.contains(cur) { source = .history }
        for item in removedHistory + removedPinned + removedBoards.flatMap(\.items) {
            deleteImageFile(item)
        }
        if let sel = selectedID, set.contains(sel) { selectFirst() }
        reconcileMultiSelection()
        scheduleSave()
    }

    /// Upserts pinboard name/color only; item membership syncs through clip records.
    func applyRemote(pinboards boards: [Pinboard]) {
        guard !boards.isEmpty else { return }
        for b in boards {
            if let i = pinboards.firstIndex(where: { $0.id == b.id }) {
                pinboards[i].name = b.name
                pinboards[i].colorHex = b.colorHex
            } else {
                pinboards.append(Pinboard(id: b.id, name: b.name, colorHex: b.colorHex, items: []))
            }
        }
        scheduleSave()
    }

    private func applyRemoteToHistory(_ item: ClipItem) {
        let replaced = history.filter { $0.id == item.id }
        history.removeAll { $0.id == item.id }
        let key = item.contentKey
        if let dupIdx = history.firstIndex(where: { $0.contentKey == key }) {
            let dup = history[dupIdx]
            if dup.createdAt >= item.createdAt {
                deleteImageFile(item)
                for old in replaced { deleteImageFile(old) }
                return
            }
            history.remove(at: dupIdx)
            deleteImageFile(dup)
        }
        insertSortedByDate(item, into: &history)
        retentionPrunedRecordNames.remove(item.id.uuidString)
        // Same-id replace: drop the old image file unless something still uses it.
        for old in replaced { deleteImageFile(old) }
    }

    private func applyRemoteToPinboard(_ item: ClipItem, boardID: UUID) {
        // Placeholder board if the clip record arrives before its Pinboard record.
        if !pinboards.contains(where: { $0.id == boardID }) {
            pinboards.append(Pinboard(id: boardID, name: "Pinboard", items: []))
        }
        guard let i = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
        // Legacy shared-id records: a pinboard clip also evicts the same id from history.
        var replaced = history.filter { $0.id == item.id }
        history.removeAll { $0.id == item.id }
        replaced += pinboards[i].items.filter { $0.id == item.id }
        pinboards[i].items.removeAll { $0.id == item.id }
        let key = item.contentKey
        if let dupIdx = pinboards[i].items.firstIndex(where: { $0.contentKey == key }) {
            let dup = pinboards[i].items[dupIdx]
            if dup.createdAt >= item.createdAt {
                deleteImageFile(item)
                for old in replaced { deleteImageFile(old) }
                return
            }
            pinboards[i].items.remove(at: dupIdx)
            deleteImageFile(dup)
        }
        insertSortedByDate(item, into: &pinboards[i].items)
        retentionPrunedRecordNames.remove(item.id.uuidString)
        // Same-id replace: drop the old image file unless something still uses it.
        for old in replaced { deleteImageFile(old) }
    }

    private func insertSortedByDate(_ item: ClipItem, into items: inout [ClipItem]) {
        let idx = items.firstIndex(where: { $0.createdAt < item.createdAt }) ?? items.endIndex
        items.insert(item, at: idx)
    }

}
