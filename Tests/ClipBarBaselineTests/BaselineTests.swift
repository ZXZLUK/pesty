import Testing
import AppKit
import SwiftUI
import Carbon.HIToolbox
@testable import ClipBar

// 基线测试：只覆盖纯值类型逻辑，不触碰单例（ClipboardStore / Settings /
// AppController 的初始化会在真实的 Application Support/Pesty 目录建文件），
// 也不构建任何窗口。目标是冻结上游行为，给后续重构一个可回归的锚点。

// MARK: - ClipItem

@Suite struct ClipItemBaselineTests {

    @Test func sameContentTextMatchesOnEqualText() {
        let a = ClipItem(type: .text, text: "hello")
        let b = ClipItem(type: .text, text: "hello")
        let c = ClipItem(type: .text, text: "world")
        #expect(a.sameContent(as: b))
        #expect(!a.sameContent(as: c))
    }

    @Test func sameContentTextAndLinkAreOneIdentity() {
        // KI-007 修复后的冻结语义：纯文本与链接只是展示分类，同一字符串即同一内容。
        let text = ClipItem(type: .text, text: "https://example.com")
        let link = ClipItem(type: .link, text: "https://example.com")
        #expect(text.sameContent(as: link))
        #expect(text.contentKey == link.contentKey)
    }

    @Test func sameContentRichTextIsDistinctFromPlain() {
        // 富文本保留 RTF 载荷，与同字符串纯文本是不同内容。
        let rich = ClipItem(type: .richText, text: "hi", rtfData: Data([1]))
        let plain = ClipItem(type: .text, text: "hi")
        #expect(!rich.sameContent(as: plain))
    }

    @Test func contentKeyIsSingleSourceOfTruth() {
        let a = ClipItem(type: .text, text: "x")
        let b = ClipItem(type: .text, text: "x")
        #expect(a.contentKey == b.contentKey)
        let img1 = ClipItem(type: .image, imageHash: "h1")
        let img2 = ClipItem(type: .image, imageHash: "h2")
        #expect(img1.contentKey != img2.contentKey)
    }

    @Test func sameContentImageUsesHashWhenPresent() {
        let a = ClipItem(type: .image, imageFileName: "a.png", imageHash: "h1")
        let b = ClipItem(type: .image, imageFileName: "b.png", imageHash: "h1")
        let c = ClipItem(type: .image, imageFileName: "c.png", imageHash: "h2")
        #expect(a.sameContent(as: b))
        #expect(!a.sameContent(as: c))
    }

    @Test func sameContentColorAndFile() {
        let ca = ClipItem(type: .color, colorHex: "#FFFFFF")
        let cb = ClipItem(type: .color, colorHex: "#FFFFFF")
        #expect(ca.sameContent(as: cb))

        let fa = ClipItem(type: .file, fileURLs: ["file:///a.txt"])
        let fb = ClipItem(type: .file, fileURLs: ["file:///a.txt"])
        #expect(fa.sameContent(as: fb))
    }

    @Test func plainTextPerType() {
        #expect(ClipItem(type: .image, imageFileName: "x.png").plainText == nil)
        #expect(ClipItem(type: .color, colorHex: "#ABCDEF").plainText == "#ABCDEF")
        #expect(ClipItem(type: .text, text: "abc").plainText == "abc")
        let file = ClipItem(type: .file, fileURLs: ["file:///tmp/a b.txt"])
        #expect(file.plainText == "/tmp/a b.txt")
    }

    @Test func displayTitlePrefersCustomTitle() {
        let item = ClipItem(type: .text, text: "body", customTitle: "My Title")
        #expect(item.displayTitle == "My Title")
    }

    @Test func displayTitleLinkShowsHost() {
        let item = ClipItem(type: .link, text: "https://example.com/path?q=1")
        #expect(item.displayTitle == "example.com")
    }

    @Test func displayTitleTruncatesToFirstLine() {
        let long = String(repeating: "x", count: 100)
        let item = ClipItem(type: .text, text: "\(long)\nsecond line")
        #expect(item.displayTitle.count == 60)
        #expect(!item.displayTitle.contains("second"))
    }

    @Test func searchableTextIncludesTitleAppAndContent() {
        let item = ClipItem(type: .text, text: "Content",
                            sourceAppName: "Safari", customTitle: "Named")
        #expect(item.searchableText.contains("named"))
        #expect(item.searchableText.contains("safari"))
        #expect(item.searchableText.contains("content"))
    }

    @Test func codableRoundTrip() throws {
        let item = ClipItem(type: .richText, text: "hi", rtfData: Data([1, 2, 3]),
                            imageFileName: nil, imageHash: nil,
                            fileURLs: ["file:///x"], colorHex: "#112233",
                            sourceBundleID: "com.example.app", sourceAppName: "Example",
                            customTitle: "T", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipItem.self, from: data)
        #expect(decoded == item)
    }
}

// MARK: - ClipType / Pinboard

@Suite struct ModelBaselineTests {

    @Test func clipTypeRawValuesRoundTrip() {
        for type in ClipType.allCases {
            #expect(ClipType(rawValue: type.rawValue) == type)
        }
    }

    @Test func clipTypeLabelAndSymbolNotEmpty() {
        for type in ClipType.allCases {
            #expect(!type.label.isEmpty)
            #expect(!type.symbol.isEmpty)
        }
    }

    @Test func pinboardDecodingWithoutColorHexThrows() {
        // 现状冻结：合成 Codable 不使用 init 默认值，缺 colorHex 的旧数据
        // 解码失败——而 ClipboardStore.load() 会把整份 store.json 静默丢弃
        // （见 RISKS.md R3）。若将来改为宽松解码，此测试应同步更新。
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","name":"Board","items":[]}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Pinboard.self, from: Data(json.utf8))
        }
    }

    @Test func pinboardDecodingCompleteRoundTrip() throws {
        var board = Pinboard(name: "Board", colorHex: "#ABCDEF")
        board.items.append(ClipItem(type: .text, text: "x"))
        let decoded = try JSONDecoder().decode(Pinboard.self, from: JSONEncoder().encode(board))
        #expect(decoded == board)
    }
}

// MARK: - Color hex

@Suite struct ColorHexBaselineTests {

    @Test func nsColorFromHexSixDigits() throws {
        let color = try #require(NSColor(hex: "#FF8000"))
        let srgb = color.usingColorSpace(.sRGB) ?? color
        #expect(abs(srgb.redComponent - 1.0) < 0.002)
        #expect(abs(srgb.greenComponent - 0x80 / 255.0) < 0.002)
        #expect(abs(srgb.blueComponent) < 0.002)
    }

    @Test func nsColorHexInvalidReturnsNil() {
        #expect(NSColor(hex: "#GGHHII") == nil)
        #expect(NSColor(hex: "12345") == nil)
        #expect(NSColor(hex: "") == nil)
    }

    @Test func nsColorHexRoundTrip() throws {
        let original = try #require(NSColor(hex: "#3366CC"))
        let round = try #require(NSColor(hex: original.hexString))
        #expect(round.hexString == original.hexString)
    }

    @Test func colorHexInvalidReturnsNil() {
        #expect(Color(hex: "nope") == nil)
        #expect(Color(hex: "#AABBCC") != nil)
    }
}

// MARK: - Hotkey 描述

@Suite @MainActor struct HotkeyDescribeBaselineTests {

    @Test func describeOrdersModifiersControlOptionShiftCommand() {
        let carbon = cmdKey | shiftKey | optionKey | controlKey
        let described = HotKeyCenter.describe(keyCode: kVK_ANSI_V, modifiers: carbon)
        #expect(described == "⌃⌥⇧⌘V")
    }

    @Test func describeDefaultHotkeyIsCmdShiftV() {
        let described = HotKeyCenter.describe(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)
        #expect(described == "⇧⌘V")
    }

    @Test func keyNameUnknownKeyCodeFallsBackToQuestionMark() {
        #expect(HotKeyCenter.keyName(for: 65535) == "?")
        #expect(HotKeyCenter.keyName(for: kVK_Space) == "Space")
        #expect(HotKeyCenter.keyName(for: kVK_ANSI_Keypad1) == "?")
    }
}

// MARK: - Clipboard Agent

@Suite @MainActor struct ClipboardAgentTests {

    @Test func presetRawValuesAndLabelsStayStable() {
        #expect(AgentCompilerPreset.allCases.map(\.rawValue) == ["quick", "spoken", "humorous", "judgments"])
        #expect(AgentCompilerPreset.quick.titleZH == "快速理解")
        #expect(AgentCompilerPreset.spoken.titleZH == "口播·平实")
        #expect(AgentCompilerPreset.humorous.titleZH == "口播·轻幽默")
        #expect(AgentCompilerPreset.judgments.titleZH == "20 条判断")
    }

    @Test func subtitleTimestampIsCompilable() {
        let text = "开场说明\n0:07\n第一段字幕内容\n0:42\n第二段字幕内容"
        #expect(AgentTrigger.looksLikeSubtitle(text))
        #expect(AgentTrigger.looksLikeCompilable(text))
    }

    @Test func compilerOutputMarkerIsOneShot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipbar-agent-marker-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = "这是 Agent 编译后的输出"
        let marker = AgentTrigger.outputMarkerURL(for: text, tempDirectory: dir)
        try "1000".write(to: marker, atomically: true, encoding: .utf8)

        #expect(AgentTrigger.consumeOutputMarkerIfPresent(text, tempDirectory: dir, nowMilliseconds: 1500))
        #expect(!AgentTrigger.consumeOutputMarkerIfPresent(text, tempDirectory: dir, nowMilliseconds: 1500))
    }

    @Test func genericLongTextRequiresExplicitRoutingIntent() {
        let longText = String(repeating: "这是一段普通长文章。", count: 100)
        #expect(!AgentTrigger.looksLikeCompilable(longText))
        let route = ClipboardAgentMetadata(v: 1, source: "youtube", kind: "transcript", intent: "compile")
        #expect(AgentTrigger.looksLikeCompilable("明确声明的字幕", metadata: route))
    }

    @Test func explicitCompileIntentSurvivesContentDedup() {
        let route = ClipboardAgentMetadata(v: 1, source: "youtube", kind: "transcript", intent: "compile")
        let routed = ClipItem(type: .text, text: "与历史完全相同的正文", agentMetadata: route)
        let ordinary = ClipItem(type: .text, text: "与历史完全相同的正文")
        let image = ClipItem(type: .image, imageHash: "same")
        #expect(AgentTrigger.shouldReevaluateDuplicate(routed))
        #expect(!AgentTrigger.shouldReevaluateDuplicate(ordinary))
        #expect(!AgentTrigger.shouldReevaluateDuplicate(image))
    }

    @Test func semanticMarkerIsRemovedBeforeCompilation() {
        let raw = "[[CLIPBAR:v1;source=youtube;kind=transcript;intent=compile]]\n0:07\n字幕正文"
        let parsed = ClipboardAgentMetadata.stripLeadingMarker(from: raw)
        #expect(parsed.metadata == ClipboardAgentMetadata(v: 1, source: "youtube", kind: "transcript", intent: "compile"))
        #expect(parsed.text == "0:07\n字幕正文")
        let invalid = ClipboardAgentMetadata.stripLeadingMarker(from: "[[CLIPBAR:v1;source=youtube;kind=transcript]]\n正文")
        #expect(invalid.metadata == nil)
        #expect(invalid.text.contains("CLIPBAR"))
    }

    @Test func webCustomFormatMapParserIsStrict() throws {
        let good = try #require("{\"application/x-clipbar-agent+json\":\"org.w3.web-custom-format.type-0\"}".data(using: .utf8))
        #expect(ClipboardAgentMetadata.mappedPasteboardType(fromWebCustomFormatMap: good) == "org.w3.web-custom-format.type-0")
        let bad = try #require("{\"application/x-clipbar-agent+json\":\"public.utf8-plain-text\"}".data(using: .utf8))
        #expect(ClipboardAgentMetadata.mappedPasteboardType(fromWebCustomFormatMap: bad) == nil)
        let payload = try #require("{\"v\":1,\"source\":\"youtube\",\"kind\":\"transcript\",\"intent\":\"compile\"}".data(using: .utf8))
        #expect(ClipboardAgentMetadata.decodeRoutingPayload(payload)?.source == "youtube")
    }

    @Test func htmlFallbackMetadataIsInvisibleAndStrict() {
        let html = "<!--CLIPBAR:v1;source=youtube;kind=transcript;intent=compile--><div>clean text</div>"
        #expect(ClipboardAgentMetadata.metadataFromHTML(html)?.source == "youtube")
        let wrapped = "<meta charset=\"utf-8\"><!--CLIPBAR:v1;source=youtube;kind=transcript;intent=compile--><div>clean text</div>"
        #expect(ClipboardAgentMetadata.metadataFromHTML(wrapped)?.kind == "transcript")
        #expect(ClipboardAgentMetadata.metadataFromHTML("<div>clean text</div>") == nil)
        #expect(ClipboardAgentMetadata.metadataFromHTML("<!--CLIPBAR:v1;source=youtube;kind=transcript-->正文") == nil)
    }

    @Test func chromiumYouTubeProgrammaticPlainTextRoutesWithoutShortcutMonitoring() {
        let programmaticTypes: Set<String> = [
            "public.utf8-plain-text",
            "NSStringPboardType",
            "org.chromium.internal.source-rfh-token",
            "org.chromium.source-url",
        ]
        #expect(ClipboardAgentMetadata.metadataFromChromiumYouTubePlainText(
            typeNames: programmaticTypes,
            sourceURL: "https://www.youtube.com/watch?v=test"
        )?.source == "youtube")
        #expect(ClipboardAgentMetadata.metadataFromChromiumYouTubePlainText(
            typeNames: programmaticTypes.union(["public.html"]),
            sourceURL: "https://www.youtube.com/watch?v=test"
        ) == nil)
        #expect(ClipboardAgentMetadata.metadataFromChromiumYouTubePlainText(
            typeNames: programmaticTypes,
            sourceURL: "https://example.com/watch?v=test"
        ) == nil)
        #expect(ClipboardAgentMetadata.metadataFromChromiumYouTubePlainText(
            typeNames: programmaticTypes.subtracting(["org.chromium.internal.source-rfh-token"]),
            sourceURL: "https://www.youtube.com/watch?v=test"
        ) == nil)
    }
}

// MARK: - 拼音索引

@Suite struct PinyinIndexTests {

    @Test func syllablesAndInitialsForCoreWords() {
        let syl = Pinyin.syllables("粘贴板")
        #expect(syl.contains("zhan"))
        #expect(syl.contains("tie"))
        #expect(syl.contains("ban"))
        #expect(Pinyin.initials("粘贴板") == "ztb")
    }

    @Test func mixedTextPassesLatinThrough() {
        let syl = Pinyin.syllables("ClipBar 粘贴板 hello")
        #expect(syl.contains("clipbar"))
        #expect(syl.contains("hello"))
        #expect(syl.contains("zhan"))
        let ini = Pinyin.initials("ClipBar 粘贴板 hello")
        #expect(ini.contains("ztb"))
    }

    @Test func punctuationDoesNotBecomeInitial() {
        // 独立标点 token 不应进入声母串。
        #expect(Pinyin.initials("你好，世界！") == "nhsj")
    }

    @Test func polyphoneContextAwareness() {
        // 系统转换按上下文取音：重庆=chong、重启=zhong。
        #expect(Pinyin.syllables("重庆之行").contains("chong"))
        #expect(Pinyin.syllables("重启电脑").contains("zhong"))
    }

    @Test func pinyinQueryDetection() {
        #expect(Pinyin.isPinyinQuery("ztb"))
        #expect(Pinyin.isPinyinQuery("zhan"))
        #expect(!Pinyin.isPinyinQuery("粘贴"))
        #expect(!Pinyin.isPinyinQuery("a b"))
        #expect(!Pinyin.isPinyinQuery("py1"))
        #expect(!Pinyin.isPinyinQuery(""))
    }

    @Test func indexJoinsSyllablesAndInitials() {
        let idx = Pinyin.index(for: "粘贴板")
        #expect(idx.contains("zhan tie ban"))
        #expect(idx.contains("ztb"))
    }
}
