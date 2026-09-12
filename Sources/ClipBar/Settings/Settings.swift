import AppKit
import Carbon.HIToolbox
import Observation

enum ShortcutModifier: CaseIterable, Identifiable {
    case command
    case option
    case control
    case shift

    var id: Int { carbonValue }

    var carbonValue: Int {
        switch self {
        case .command: return cmdKey
        case .option: return optionKey
        case .control: return controlKey
        case .shift: return shiftKey
        }
    }

    var title: String {
        switch self {
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        case .shift: return "Shift"
        }
    }

    var titleZH: String {
        switch self {
        case .command: return "Command 键"
        case .option: return "Option 键"
        case .control: return "Control 键"
        case .shift: return "Shift 键"
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    init?(carbonValue: Int) {
        guard let modifier = Self.allCases.first(where: { $0.carbonValue == carbonValue }) else {
            return nil
        }
        self = modifier
    }
}

enum HistoryRetentionMode: String, CaseIterable, Identifiable {
    case itemCount
    case timeInterval

    var id: String { rawValue }

    var title: String {
        switch self {
        case .itemCount: return "Number of clips"
        case .timeInterval: return "Age of clips"
        }
    }

    var titleZH: String {
        switch self {
        case .itemCount: return "按数量"
        case .timeInterval: return "按时间"
        }
    }
}

@Observable
@MainActor
final class Settings {
    static let shared = Settings()

    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored private var isLoaded = false

    enum Keys {
        static let historyLimit = "historyLimit"
        static let historyRetentionMode = "historyRetentionMode"
        static let historyRetentionDays = "historyRetentionDays"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let quickPasteModifier = "quickPasteModifier"
        static let plainTextModifier = "plainTextModifier"
        static let launchAtLogin = "launchAtLogin"
        static let hideOnClickOutside = "hideOnClickOutside"
        static let pasteDirectly = "pasteDirectly"
        static let playSound = "playSound"
        static let captureSound = "captureSound"
        static let ignoreConcealed = "ignoreConcealed"
        static let ignoredSourceAppBundleIDs = "ignoredSourceAppBundleIDs"
        static let barHeight = "barHeight"
        static let showFromTop = "showFromTop"
        static let hotEdgeEnabled = "hotEdgeEnabled"
        static let lowerHalfDismiss = "lowerHalfDismiss"
        static let smartFocusInput = "smartFocusInput"
        static let subtitleTriggerEnabled = "subtitleTriggerEnabled"
        static let subtitleScript = "subtitleScript"
        static let linkRules = "linkRules"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let onboarded = "onboarded"
        static let barHeightSlimmed = "barHeightSlimmed"
    }

    var historyLimit: Int {
        didSet {
            guard isLoaded else { return }
            if historyLimit < 20 { historyLimit = 20; return }
            d.set(historyLimit, forKey: Keys.historyLimit)
        }
    }

    var historyRetentionMode: HistoryRetentionMode {
        didSet {
            guard isLoaded else { return }
            d.set(historyRetentionMode.rawValue, forKey: Keys.historyRetentionMode)
        }
    }

    var historyRetentionDays: Int {
        didSet {
            guard isLoaded else { return }
            if historyRetentionDays < 1 { historyRetentionDays = 1; return }
            d.set(historyRetentionDays, forKey: Keys.historyRetentionDays)
        }
    }

    var hotkeyKeyCode: Int {
        didSet { guard isLoaded else { return }
            d.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode); HotKeyCenter.shared.reload() }
    }

    var hotkeyModifiers: Int {
        didSet { guard isLoaded else { return }
            d.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers); HotKeyCenter.shared.reload() }
    }

    var quickPasteModifier: Int {
        didSet {
            guard isLoaded else { return }
            if quickPasteModifier == plainTextModifier { plainTextModifier = oldValue }
            d.set(quickPasteModifier, forKey: Keys.quickPasteModifier)
        }
    }

    var plainTextModifier: Int {
        didSet {
            guard isLoaded else { return }
            if plainTextModifier == quickPasteModifier { quickPasteModifier = oldValue }
            d.set(plainTextModifier, forKey: Keys.plainTextModifier)
        }
    }

    var launchAtLogin: Bool {
        didSet { guard isLoaded else { return }
            d.set(launchAtLogin, forKey: Keys.launchAtLogin); LaunchAtLogin.set(enabled: launchAtLogin) }
    }

    var hideOnClickOutside: Bool {
        didSet { guard isLoaded else { return }; d.set(hideOnClickOutside, forKey: Keys.hideOnClickOutside) }
    }

    var pasteDirectly: Bool {
        didSet { guard isLoaded else { return }; d.set(pasteDirectly, forKey: Keys.pasteDirectly) }
    }

    var playSound: Bool {
        didSet { guard isLoaded else { return }; d.set(playSound, forKey: Keys.playSound) }
    }

    /// System sound name played (quietly) when a new clip is captured;
    /// empty string disables capture feedback.
    var captureSound: String {
        didSet { guard isLoaded else { return }; d.set(captureSound, forKey: Keys.captureSound) }
    }

    var ignoreConcealed: Bool {
        didSet { guard isLoaded else { return }; d.set(ignoreConcealed, forKey: Keys.ignoreConcealed) }
    }

    /// Applications whose copied content should never be recorded in history.
    /// Store bundle identifiers rather than paths so the choice continues to work
    /// when an app is updated or moved.
    private(set) var ignoredSourceAppBundleIDs: [String] {
        didSet { guard isLoaded else { return }; d.set(ignoredSourceAppBundleIDs, forKey: Keys.ignoredSourceAppBundleIDs) }
    }

    var barHeight: Double {
        didSet {
            guard isLoaded else { return }
            let clamped = min(720, max(240, barHeight))
            if clamped != barHeight { barHeight = clamped; return }
            d.set(barHeight, forKey: Keys.barHeight)
        }
    }

    /// Dock the bar to the top edge of the screen and slide it down on show.
    /// false keeps the original bottom-edge, slide-up behaviour.
    var showFromTop: Bool {
        didSet { guard isLoaded else { return }; d.set(showFromTop, forKey: Keys.showFromTop) }
    }

    /// Park the cursor on the screen's topmost line to summon the bar
    /// (invisible hot-edge strips, 0.25s dwell).
    var hotEdgeEnabled: Bool {
        didSet {
            guard isLoaded else { return }
            d.set(hotEdgeEnabled, forKey: Keys.hotEdgeEnabled)
            AppController.shared.setHotEdgeEnabled(hotEdgeEnabled)
        }
    }

    /// Moving the mouse into the screen's lower half while the bar is up
    /// dismisses it ("I moved on") — the natural counterpart to the top-edge summon.
    var lowerHalfDismiss: Bool {
        didSet { guard isLoaded else { return }; d.set(lowerHalfDismiss, forKey: Keys.lowerHalfDismiss) }
    }

    /// On paste, locate the target app's text input via Accessibility and focus
    /// it before injecting ⌘V — the prompt box gets the text even if focus was
    /// elsewhere in that app.
    var smartFocusInput: Bool {
        didSet { guard isLoaded else { return }; d.set(smartFocusInput, forKey: Keys.smartFocusInput) }
    }

    /// Link-trigger rules: a captured link whose host matches a rule's domain
    /// immediately runs that rule's action (open in browser / run a script).
    /// Data-driven: add or edit rows in Settings → Rules.
    var linkRules: [LinkRule] {
        didSet { guard isLoaded else { return }; persist() }
    }

    /// 字幕自动处理：捕获的文本具备字幕特征（≥2 行时间轴）时，自动运行
    /// 用户脚本（字幕全文作为 $1）。总开关——不需要时整体关闭。
    var subtitleTriggerEnabled: Bool {
        didSet { guard isLoaded else { return }; d.set(subtitleTriggerEnabled, forKey: Keys.subtitleTriggerEnabled) }
    }

    /// 字幕处理脚本（zsh，$1 = 字幕全文），内联编辑。
    var subtitleScript: String {
        didSet { guard isLoaded else { return }; d.set(subtitleScript, forKey: Keys.subtitleScript) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(linkRules) else { return }
        d.set(data, forKey: Keys.linkRules)
    }

    var showMenuBarIcon: Bool {
        didSet {
            guard isLoaded else { return }
            d.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon)
            AppController.shared.setMenuBarIconVisible(showMenuBarIcon)
        }
    }

    var onboarded: Bool {
        didSet { guard isLoaded else { return }; d.set(onboarded, forKey: Keys.onboarded) }
    }

    private init() {
        d.register(defaults: [
            Keys.historyLimit: 500,
            Keys.historyRetentionMode: HistoryRetentionMode.itemCount.rawValue,
            Keys.historyRetentionDays: 30,
            Keys.hotkeyKeyCode: kVK_ANSI_V,
            Keys.hotkeyModifiers: cmdKey | shiftKey,
            Keys.quickPasteModifier: cmdKey,
            Keys.plainTextModifier: shiftKey,
            Keys.launchAtLogin: false,
            Keys.hideOnClickOutside: true,
            Keys.pasteDirectly: true,
            Keys.playSound: false,
            Keys.captureSound: "Tink",
            Keys.ignoreConcealed: true,
            Keys.ignoredSourceAppBundleIDs: [],
            Keys.barHeight: 365.0,
            Keys.showFromTop: true,
            Keys.hotEdgeEnabled: true,
            Keys.lowerHalfDismiss: true,
            Keys.smartFocusInput: true,
            Keys.subtitleTriggerEnabled: true,
            Keys.subtitleScript: "",
            Keys.showMenuBarIcon: true,
            Keys.onboarded: false
        ])
        historyLimit = d.integer(forKey: Keys.historyLimit)
        historyRetentionMode = HistoryRetentionMode(rawValue: d.string(forKey: Keys.historyRetentionMode) ?? "")
            ?? .itemCount
        historyRetentionDays = max(1, d.integer(forKey: Keys.historyRetentionDays))
        hotkeyKeyCode = d.integer(forKey: Keys.hotkeyKeyCode)
        hotkeyModifiers = d.integer(forKey: Keys.hotkeyModifiers)
        quickPasteModifier = d.integer(forKey: Keys.quickPasteModifier)
        plainTextModifier = d.integer(forKey: Keys.plainTextModifier)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        hideOnClickOutside = d.bool(forKey: Keys.hideOnClickOutside)
        pasteDirectly = d.bool(forKey: Keys.pasteDirectly)
        playSound = d.bool(forKey: Keys.playSound)
        captureSound = d.string(forKey: Keys.captureSound) ?? "Tink"
        ignoreConcealed = d.bool(forKey: Keys.ignoreConcealed)
        // First run only (key never written): pre-exclude common password
        // managers so secrets never land in history before the user opens
        // Privacy settings. Users can remove entries freely afterwards.
        if d.object(forKey: Keys.ignoredSourceAppBundleIDs) == nil {
            let presets = [
                "com.agilebits.onepassword-osx",   // 1Password 7/8
                "com.1password.1password",         // 1Password (newer)
                "com.bitwarden.desktop",           // Bitwarden
                "com.dashlane.dashlanephoneagent", // Dashlane
                "in.enpass.desktop",               // Enpass
                "org.keepassxc.keepassxc",         // KeePassXC
                "com.starkmarks.scarab",           // Strongbox
            ].sorted()
            ignoredSourceAppBundleIDs = presets
            d.set(presets, forKey: Keys.ignoredSourceAppBundleIDs)
        } else {
            ignoredSourceAppBundleIDs = (d.stringArray(forKey: Keys.ignoredSourceAppBundleIDs) ?? [])
                .filter { !$0.isEmpty }
        }
        // One-time slim-down (2026-09-07): tighter layout ships with a shorter
        // bar. Applies once to whatever height is stored, then never again.
        if !d.bool(forKey: Keys.barHeightSlimmed) {
            let slimmed = min(720, max(300, d.double(forKey: Keys.barHeight) * 0.85))
            d.set(slimmed, forKey: Keys.barHeight)
            d.set(true, forKey: Keys.barHeightSlimmed)
        }
        barHeight = d.double(forKey: Keys.barHeight)
        showFromTop = d.bool(forKey: Keys.showFromTop)
        hotEdgeEnabled = d.bool(forKey: Keys.hotEdgeEnabled)
        lowerHalfDismiss = d.bool(forKey: Keys.lowerHalfDismiss)
        smartFocusInput = d.bool(forKey: Keys.smartFocusInput)
        subtitleTriggerEnabled = d.bool(forKey: Keys.subtitleTriggerEnabled)
        subtitleScript = d.string(forKey: Keys.subtitleScript) ?? ""
        if let data = d.data(forKey: Keys.linkRules),
           let decoded = try? JSONDecoder().decode([LinkRule].self, from: data) {
            linkRules = decoded
            NSLog("QuickNoteDebug: linkRules decoded count=%d", decoded.count)
            for r in decoded {
                NSLog("QuickNoteDebug: rule domain=%@ enabled=%d action=%@", r.domain, r.enabled ? 1 : 0, String(describing: r.action))
            }
        } else {
            NSLog("QuickNoteDebug: linkRules decode FAILED, using seed")
            linkRules = [LinkRule(domain: "mp.weixin.qq.com", action: .openInBrowser)]
        }
        showMenuBarIcon = d.bool(forKey: Keys.showMenuBarIcon)
        onboarded = d.bool(forKey: Keys.onboarded)
        isLoaded = true
    }

    var hotkeyDisplay: String {
        HotKeyCenter.describe(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    var quickPasteModifierDisplay: String {
        ShortcutModifier(carbonValue: quickPasteModifier)?.symbol ?? "⌘"
    }

    func isIgnoringSourceApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredSourceAppBundleIDs.contains(bundleID)
    }

    func addIgnoredSourceApp(_ bundleID: String) {
        guard !bundleID.isEmpty, !ignoredSourceAppBundleIDs.contains(bundleID) else { return }
        ignoredSourceAppBundleIDs.append(bundleID)
        ignoredSourceAppBundleIDs.sort()
    }

    func removeIgnoredSourceApp(_ bundleID: String) {
        ignoredSourceAppBundleIDs.removeAll { $0 == bundleID }
    }
}
