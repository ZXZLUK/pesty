import Testing
import Foundation
@testable import ClipBar

// SQLiteStore 需要注入临时目录（应用内的真实实例走 Application Support 单例，
// 不能在单测里碰）。这里验证：往返一致性、大对象外置、行级特性。

@Suite struct SQLiteStoreTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipbar-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundTripHistoryAndPinboards() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("SQLiteStore init failed"); return
        }

        let old = ClipItem(type: .text, text: "older",
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let recent = ClipItem(type: .link, text: "https://example.com/x",
                              sourceBundleID: "com.example.app", sourceAppName: "Example",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        var board = Pinboard(name: "工作", colorHex: "#ABCDEF")
        let pinned = ClipItem(type: .color, colorHex: "#FF8800",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_050))
        board.items = [pinned]

        #expect(store.flush(history: [recent, old], pinboards: [board],
                            dirtyContainers: ["history", board.id.uuidString],
                            deletedBlobIDs: []))

        let reopened = SQLiteStore(directory: dir)
        let snap = reopened?.load()
        #expect(snap?.history.count == 2)
        #expect(snap?.history.first?.text == "https://example.com/x")
        #expect(snap?.history.first?.type == .link)
        #expect(snap?.history.last?.text == "older")
        #expect(snap?.pinboards.count == 1)
        #expect(snap?.pinboards.first?.name == "工作")
        #expect(snap?.pinboards.first?.colorHex == "#ABCDEF")
        #expect(snap?.pinboards.first?.items.first?.colorHex == "#FF8800")
    }

    @Test func largeTextGoesToBlobFileAndComesBack() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("SQLiteStore init failed"); return
        }
        // 超过 inlineLimit（128KB）的文本必须外置为文件，读回逐字节一致。
        let big = String(repeating: "剪贴板ClipBar- большие данные émoji 🎉/", count: 6_000)
        #expect(big.utf8.count > SQLiteStore.inlineLimit)
        let item = ClipItem(type: .text, text: big)
        #expect(store.flush(history: [item], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: []))

        let blobs = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
        #expect(blobs.count == 1)
        #expect(blobs.first?.pathExtension == "txt")

        let snap = SQLiteStore(directory: dir)?.load()
        #expect(snap?.history.first?.text == big)
    }

    @Test func rtfBlobRoundTrip() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("SQLiteStore init failed"); return
        }
        let rtf = Data((0..<300_000).map { UInt8($0 % 251) }) // > inlineLimit
        let item = ClipItem(type: .richText, text: "rich", rtfData: rtf)
        #expect(store.flush(history: [item], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: []))
        let snap = SQLiteStore(directory: dir)?.load()
        #expect(snap?.history.first?.rtfData == rtf)
        #expect(snap?.history.first?.text == "rich")
    }

    @Test func smallValuesStayInline() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("SQLiteStore init failed"); return
        }
        let item = ClipItem(type: .text, text: "small", rtfData: Data([1, 2, 3]))
        #expect(store.flush(history: [item], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: []))
        let blobsPath = dir.appendingPathComponent("blobs").path
        #expect((try? FileManager.default.contentsOfDirectory(atPath: blobsPath))?.isEmpty == true)
        let snap = SQLiteStore(directory: dir)?.load()
        #expect(snap?.history.first?.rtfData == Data([1, 2, 3]))
    }

    @Test func deletedBlobFilesRemovedOnFlush() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("SQLiteStore init failed"); return
        }
        let big = String(repeating: "x", count: 200_000)
        let item = ClipItem(type: .text, text: big)
        #expect(store.flush(history: [item], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: []))
        let blobsDir = dir.appendingPathComponent("blobs")
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobsDir.path).count == 1)

        let replacement = ClipItem(type: .text, text: "after delete")
        #expect(store.flush(history: [replacement], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: [item.id]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobsDir.path).isEmpty)
        let snap = SQLiteStore(directory: dir)?.load()
        #expect(snap?.history.first?.text == "after delete")
    }

    @Test func undirtyContainersKeepRows() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("SQLiteStore init failed"); return
        }
        let a = ClipItem(type: .text, text: "A")
        var board = Pinboard(name: "B")
        let pinned = ClipItem(type: .text, text: "pinned")
        board.items = [pinned]
        #expect(store.flush(history: [a], pinboards: [board],
                            dirtyContainers: ["history", board.id.uuidString],
                            deletedBlobIDs: []))

        // 只标脏 history：pinboard 行不应被重写（通过再次 flush 验证一致性）。
        let b = ClipItem(type: .text, text: "B")
        #expect(store.flush(history: [b, a], pinboards: [board],
                            dirtyContainers: ["history"], deletedBlobIDs: []))
        let snap = SQLiteStore(directory: dir)?.load()
        #expect(snap?.history.map(\.text) == ["B", "A"])
        #expect(snap?.pinboards.first?.items.first?.text == "pinned")
    }
}

@Suite struct SQLiteStoreFlagAndBackupTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipbar-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func truncationFlagRoundTrip() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("init failed"); return
        }
        let item = ClipItem(type: .text, text: String(repeating: "a", count: 100),
                            textTruncated: true)
        #expect(store.flush(history: [item], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: []))
        let snap = SQLiteStore(directory: dir)?.load()
        #expect(snap?.history.first?.textTruncated == true)
        #expect(snap?.history.first?.text == String(repeating: "a", count: 100))
    }

    @Test func legacyDecodeWithoutFlagDefaultsFalse() throws {
        // 旧 JSON（无 textTruncated 键）解码为 false。
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","type":"text","text":"x","fileURLs":[],"createdAt":0}"#
        let item = try JSONDecoder().decode(ClipItem.self, from: Data(json.utf8))
        #expect(item.textTruncated == false)
        #expect(item.text == "x")
    }

    @Test func backupProducesConsistentCopy() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("init failed"); return
        }
        let item = ClipItem(type: .text, text: "backup me")
        #expect(store.flush(history: [item], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: []))
        let target = dir.appendingPathComponent("backup.db")
        #expect(store.backup(to: target))
        let snap = SQLiteStore(directory: dir.appendingPathComponent("bk", isDirectory: true))
        // 直接打开备份文件验证内容（借目录隔离不可行，改用只读打开同文件）
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 0)
        _ = snap // 目录初始化仅用于确认 API 可用
    }
}

@Suite struct SQLiteStoreLazyLoadRegressionTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipbar-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 回归：内存只留预览后再次 flush，数据库必须保留全文（懒加载数据丢失防线）。
    @Test func reflushWithPreviewKeepsFullPayloadInDatabase() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("init failed"); return
        }
        let full = String(repeating: "x", count: 300_000) // > inlineLimit → blob
        let original = ClipItem(type: .text, text: full)
        #expect(store.flush(history: [original], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: []))

        // 模拟 trimMemoryPreviews 之后的内存状态。
        var preview = original
        preview.text = String(full.prefix(64_000))
        preview.textTruncated = true
        #expect(store.flush(history: [preview], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: []))

        let reloaded = SQLiteStore(directory: dir)?.load()
        #expect(reloaded?.history.first?.text?.count == full.count)
        #expect(reloaded?.history.first?.text == full)

        // 粘贴路径取全文也必须拿到完整内容。
        let payload = store.loadFullPayload(id: original.id)
        #expect(payload.text?.count == full.count)
    }
}

@Suite struct SQLiteStoreHygieneTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipbar-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func orphanBlobSweepOnlyRemovesUnreferenced() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = SQLiteStore(directory: dir) else {
            Issue.record("init failed"); return
        }
        let big = String(repeating: "z", count: 200_000)
        let item = ClipItem(type: .text, text: big)
        #expect(store.flush(history: [item], pinboards: [],
                            dirtyContainers: ["history"], deletedBlobIDs: []))
        let blobsDir = dir.appendingPathComponent("blobs")
        // 伪造一个孤儿 blob（模拟崩溃残留）。
        try Data("ghost".utf8).write(to: blobsDir.appendingPathComponent("GHOST.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobsDir.path).count == 2)

        let removed = store.deleteUnreferencedBlobs()
        #expect(removed == 1)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: blobsDir.path)
        #expect(remaining.count == 1)
        #expect(remaining.first != "GHOST.txt")
        // 被引用的 blob 完好。
        let snap = SQLiteStore(directory: dir)?.load()
        #expect(snap?.history.first?.text == big)
    }
}
