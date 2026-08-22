import AppKit

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var type: ClipType
    var text: String?
    var rtfData: Data?
    var imageFileName: String?
    var imageHash: String?
    var fileURLs: [String]
    var colorHex: String?

    var sourceBundleID: String?
    var sourceAppName: String?

    var customTitle: String?
    var createdAt: Date

    /// True when `text`/`rtfData` hold only a memory preview (first
    /// `ClipboardStore.memoryPreviewLimit` bytes) and the full payload lives in
    /// the database. Paste/edit paths must fetch the full content via
    /// `ClipboardStore.fullText/fullRTF`. Old data decodes with `false`.
    var textTruncated: Bool = false

    init(id: UUID = UUID(),
         type: ClipType,
         text: String? = nil,
         rtfData: Data? = nil,
         imageFileName: String? = nil,
         imageHash: String? = nil,
         fileURLs: [String] = [],
         colorHex: String? = nil,
         sourceBundleID: String? = nil,
         sourceAppName: String? = nil,
         customTitle: String? = nil,
         createdAt: Date = Date(),
         textTruncated: Bool = false) {
        self.id = id
        self.type = type
        self.text = text
        self.rtfData = rtfData
        self.imageFileName = imageFileName
        self.imageHash = imageHash
        self.fileURLs = fileURLs
        self.colorHex = colorHex
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.customTitle = customTitle
        self.createdAt = createdAt
        self.textTruncated = textTruncated
    }

    enum CodingKeys: String, CodingKey {
        case id, type, text, rtfData, imageFileName, imageHash
        case fileURLs, colorHex, sourceBundleID, sourceAppName, customTitle
        case createdAt, textTruncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(ClipType.self, forKey: .type)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        rtfData = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName)
        imageHash = try c.decodeIfPresent(String.self, forKey: .imageHash)
        fileURLs = try c.decodeIfPresent([String].self, forKey: .fileURLs) ?? []
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceAppName = try c.decodeIfPresent(String.self, forKey: .sourceAppName)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        textTruncated = try c.decodeIfPresent(Bool.self, forKey: .textTruncated) ?? false
    }

    var charCount: Int { text?.count ?? 0 }

    var plainText: String? {
        switch type {
        case .image:
            return nil
        case .color:
            return colorHex
        case .file:
            let paths = fileURLs.map { URL(string: $0)?.path ?? $0 }
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        case .text, .richText, .link:
            return text
        }
    }

    var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }
        switch type {
        case .link:
            if let t = text, let url = URL(string: t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url.host ?? t
            }
            return text ?? "Link"
        case .image:
            return imageFileName != nil ? "Image" : "Image"
        case .file:
            return fileURLs.first.flatMap { URL(string: $0)?.lastPathComponent } ?? "File"
        case .color:
            return colorHex ?? "Color"
        default:
            let firstLine = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return firstLine.isEmpty ? type.label : String(firstLine.prefix(60))
        }
    }

    var searchableText: String {
        [customTitle, text, sourceAppName, fileURLs.joined(separator: " "), colorHex]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    func sameContent(as other: ClipItem) -> Bool {
        guard type == other.type else { return false }
        switch type {
        case .image:
            if let h = imageHash, let oh = other.imageHash { return h == oh }
            return imageFileName == other.imageFileName
        case .color:
            return colorHex == other.colorHex
        case .file:
            return fileURLs == other.fileURLs
        default:
            return text == other.text
        }
    }
}
