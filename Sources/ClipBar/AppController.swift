import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let shared = AppController()

    let store = ClipboardStore.shared
    let monitor = ClipboardMonitor()

    private var barController: BarWindowController?
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var previewedItemID: UUID?
    private var keyMonitor: Any?

    private(set) var previousApp: NSRunningApplication?
    private(set) var lastActiveApp: NSRunningApplication?

    var suppressAutoHide = false

    /// When the search query last became empty via the keyboard. A bare
    /// Backspace deletes the selected clip, and the keystroke that clears the
    /// query must stay unambiguously separate from the keystroke that deletes.
    private var searchClearedAt: Date = .distantPast
    private static let deleteAfterSearchClearCooldown: TimeInterval = 0.6

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        monitor.start()
        store.applyRetentionPolicy()

        HotKeyCenter.shared.onTrigger = { [weak self] in self?.toggleBar() }
        HotKeyCenter.shared.start()

        setMenuBarIconVisible(Settings.shared.showMenuBarIcon)

        if Settings.shared.launchAtLogin { LaunchAtLogin.set(enabled: true) }

        #if MAS
        // CKSyncEngine handles the push payloads itself; the app only registers.
        NSApplication.shared.registerForRemoteNotifications()
        if Settings.shared.cloudKitSync { CloudSyncService.shared.start() }
        #endif

        if CommandLine.arguments.contains("--demo") {
            store.seedDemo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showBar()
            }
            return
        }

        if !Settings.shared.onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
            }
            Settings.shared.onboarded = true
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveApp = app
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow(wait: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === previewWindow {
            previewedItemID = nil
        }
    }

    /// Reopening from Finder, Spotlight, or the Dock surfaces the app.
    ///
    /// The escape hatch comes first: ClipBar is an accessory app, so with the status
    /// item hidden there is no Dock icon, no window, and no menu - and if the global
    /// hotkey failed to register because another app already owns the combination,
    /// there is no way back in at all short of deleting the preference from Terminal.
    /// Opening ClipBar again brings the icon back and shows Settings so the user can
    /// fix whatever forced the relaunch.
    ///
    /// A normal reopen shows the Paste Bar - the primary interface should be
    /// discoverable without the keyboard shortcut. `hasVisibleWindows` cannot be
    /// trusted for that decision because the bar is an NSPanel, so ask the explicit
    /// presentation state instead; a duplicate reopen event coalesces naturally
    /// because `isPresented` flips as soon as the first show begins.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !Settings.shared.showMenuBarIcon {
            Settings.shared.showMenuBarIcon = true
            setMenuBarIconVisible(true)
            showSettings()
            return true
        }
        if barController?.isPresented != true {
            showBar()
        }
        return true
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.t("About ClipBar", "关于 ClipBar"), action: #selector(menuAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("Settings…", "设置…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("Hide ClipBar", "隐藏 ClipBar"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L10n.t("Quit ClipBar", "退出 ClipBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: L10n.t("Undo", "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.t("Redo", "重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.t("Cut", "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t("Copy", "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.t("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: L10n.t("Find…", "查找…"),
                                    action: #selector(NSTextView.performTextFinderAction(_:)),
                                    keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: L10n.t("Close Window", "关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L10n.t("Minimize", "最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemIcon(item)
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.t("Open ClipBar   \(Settings.shared.hotkeyDisplay)", "打开 ClipBar   \(Settings.shared.hotkeyDisplay)"),
                     action: #selector(menuOpen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("Settings…", "设置…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
        let pause = menu.addItem(withTitle: L10n.t("Pause ClipBar", "暂停 ClipBar"), action: #selector(menuTogglePause), keyEquivalent: "")
        pause.target = self
        pauseMenuItem = pause
        menu.addItem(withTitle: L10n.t("Clear History", "清空历史"), action: #selector(menuClear), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: L10n.t("About ClipBar", "关于 ClipBar"), action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(withTitle: L10n.t("Quit ClipBar", "退出 ClipBar"), action: #selector(menuQuit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        if visible {
            setupStatusItem()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func menuOpen() { showBar() }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuClear() { store.clearHistory() }
    @objc private func menuTogglePause() { toggleClipBarPause() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuAbout() { showAbout() }

    /// ⌘⇧T: cycle the bar through 全部 → 文本 → … → 颜色 → 全部.
    func cycleTypeFilter() {
        let all = ClipType.allCases
        guard let current = store.typeFilter,
              let idx = all.firstIndex(of: current) else {
            store.typeFilter = all.first
            return
        }
        store.typeFilter = all[(idx + 1) % all.count]
    }

    func toggleClipBarPause() {
        monitor.togglePause()
        pauseMenuItem?.title = monitor.isPaused ? L10n.t("Resume ClipBar", "恢复 ClipBar") : L10n.t("Pause ClipBar", "暂停 ClipBar")
        if let item = statusItem { updateStatusItemIcon(item) }
    }

    private func updateStatusItemIcon(_ item: NSStatusItem) {
        // Colored app-icon thumbnail instead of a monochrome template symbol:
        // menu bars crowded with dark icons make a template glyph easy to miss.
        if monitor.isPaused {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange, .white])
            let paused = NSImage(systemSymbolName: "pause.circle.fill",
                                 accessibilityDescription: "ClipBar paused")?
                .withSymbolConfiguration(config)
            item.button?.image = paused
            item.button?.image?.isTemplate = false
            return
        }
        let source = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        let target = NSSize(width: 18, height: 18)
        let image = NSImage(size: target)
        image.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: target),
                    from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        item.button?.image = image
        item.button?.image?.isTemplate = false
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ClipBar",
            .applicationVersion: Bundle.main.appVersion,
            .credits: NSAttributedString(
                string: "A free, open-source clipboard manager for macOS.\nInspired by Paste.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        ])
    }

    func toggleICloudSync() {
        // Multi-Mac sync is parked until its semantics are redesigned
        // (KNOWN_ISSUES KI-008/009: union merges resurrect deletions; the old
        // whole-file watcher does not survive the SQLite migration). History
        // stays on this Mac, which is also the privacy-safe default.
        let alert = NSAlert()
        alert.messageText = L10n.t("Sync unavailable", "同步暂不可用")
        alert.informativeText = L10n.t(
            "Multi-Mac sync is being rebuilt on the new database and is temporarily disabled. Your history stays on this Mac.",
            "多设备同步正在基于新数据库重新设计中，暂时停用。你的历史数据只保存在本机。")
        alert.runModal()
    }

    static func restart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    func toggleBar() {
        if let bar = barController, bar.isPresented {
            hideBar()
        } else {
            showBar()
        }
    }

    /// A sleep cycle can strand the bar mid-transition and can drop the Carbon hotkey.
    /// Reset both rather than trying to reason about what survived.
    @objc private func systemDidWake() {
        barController?.forceHide()
        stopKeyMonitor()
        HotKeyCenter.shared.reload()
    }

    /// Docking, undocking, and resolution changes can leave the bar sized for a screen
    /// that no longer exists. Drop it so the next open re-measures.
    ///
    /// This deliberately does NOT re-register the hotkey. That notification also fires
    /// for things as minor as a colour-profile change, and a transient
    /// RegisterEventHotKey failure during display churn would leave the app with no
    /// hotkey at all until the next relaunch - the exact bug this is meant to fix.
    @objc private func screenParametersChanged() {
        barController?.forceHide()
        stopKeyMonitor()
    }

    func showBar() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, !isClipBar(front) {
            previousApp = front
            lastActiveApp = front
        }
        store.searchText = ""
        store.source = .history
        store.prepareForBarPresentation()

        // Rebuild if the panel was ever torn down - a nil window is another way the
        // bar silently stops appearing.
        if barController == nil || barController?.window == nil {
            barController = BarWindowController()
        }
        barController?.show()
        startKeyMonitor()
    }

    func hideBar() {
        stopKeyMonitor()
        barController?.hide()
    }

    func pasteSelected() {
        guard let item = store.selectedItem else { return }
        pasteItem(item)
    }

    /// The app that will receive a paste after the floating ClipBar panel closes.
    /// `previousApp` is captured before the panel activates, while
    /// `lastActiveApp` covers menu-bar and reopen paths where it is unavailable.
    private var pasteTarget: NSRunningApplication? {
        [lastActiveApp, previousApp, NSWorkspace.shared.frontmostApplication]
            .compactMap { $0 }
            .first { !$0.isTerminated && !isClipBar($0) }
    }

    private func isClipBar(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return app.bundleIdentifier == bundleID
    }

    func pasteItem(_ item: ClipItem, asPlainText: Bool = false) {
        let target = pasteTarget
        hideBar()
        PasteService.paste(item, into: target, monitor: monitor, asPlainText: asPlainText)
    }

    func copyItem(_ item: ClipItem) {
        if let change = PasteService.copy(item) {
            monitor.suppressUntilChangeCount = change
        }
        hideBar()
    }

    var pasteMenuTitle: String {
        guard let name = pasteTarget?.localizedName,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.t("Paste", "粘贴")
        }
        return "Paste to \(name)"
    }

    func editItem(_ item: ClipItem, launchWritingTools: Bool = false) {
        suppressAutoHide = true
        defer { suppressAutoHide = false }

        // Editors need the whole payload even when memory keeps only a preview.
        var full = item
        if item.textTruncated {
            full.text = store.fullText(for: item)
            full.rtfData = store.fullRTF(for: item)
            full.textTruncated = false
        }
        guard let edit = ClipEditor.run(for: full, launchWritingTools: launchWritingTools) else { return }

        let changed: Bool
        switch edit {
        case let .text(text, richTextData):
            changed = store.updateTextContent(text, richTextData: richTextData, for: item)
        case let .color(hex):
            changed = store.updateColorContent(hex, for: item)
        }
        guard changed, let updated = store.item(withID: item.id) else { return }
        if previewedItemID == item.id { showPreview(for: updated) }
    }

    func showPreview(for item: ClipItem) {
        suppressAutoHide = true
        defer { suppressAutoHide = false }
        NSApp.activate(ignoringOtherApps: true)

        let host = NSHostingController(rootView: ClipPreviewView(item: item))
        let title = "Preview — \(item.displayTitle)"
        previewedItemID = item.id

        if let window = previewWindow {
            window.title = title
            window.contentViewController = host
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 400))
        window.minSize = NSSize(width: 400, height: 260)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        previewWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func showSharePicker(for item: ClipItem) {
        let items = shareItems(for: item)
        guard !items.isEmpty,
              let view = barController?.window?.contentView ?? NSApp.keyWindow?.contentView else { return }
        suppressAutoHide = true
        defer { suppressAutoHide = false }
        let picker = NSSharingServicePicker(items: items)
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }

    private func shareItems(for item: ClipItem) -> [Any] {
        switch item.type {
        case .image:
            return store.loadImage(for: item).map { [$0] } ?? []
        case .file:
            let urls = item.fileURLs.compactMap(URL.init(string:)).filter(\.isFileURL)
            return urls.isEmpty ? (item.plainText.map { [$0 as NSString] } ?? []) : urls
        case .color, .text, .richText, .link:
            return item.plainText.map { [$0 as NSString] } ?? []
        }
    }

    func deleteEffectiveSelection() {
        let selection = store.effectiveSelectionIDs
        let targets = store.visibleItems.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            store.delete(targets[0])
            return
        }
        suppressAutoHide = true
        defer { suppressAutoHide = false }
        let alert = NSAlert()
        alert.messageText = L10n.t("Delete \(targets.count) Clips?", "删除 \(targets.count) 条？")
        #if MAS
        alert.informativeText = L10n.t("There is no undo. When iCloud sync is on, these clips are also removed from your other devices.", "此操作无法撤销。开启 iCloud 同步时，其他设备上的这些内容也会被移除。")
        #else
        alert.informativeText = L10n.t("There is no undo.", "此操作无法撤销。")
        #endif
        let confirm = alert.addButton(withTitle: L10n.t("Delete \(targets.count) Clips", "删除 \(targets.count) 条"))
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: L10n.t("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.delete(items: targets)
    }

    func deleteSelection(containing item: ClipItem) {
        if store.multiSelectedIDs.contains(item.id) {
            deleteEffectiveSelection()
        } else {
            store.delete(item)
        }
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView()
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = L10n.t("ClipBar Settings", "ClipBar 设置")
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 520, height: 560))
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    /// Handles commands that only apply while the Paste Bar owns keyboard focus.
    /// The panel's key-equivalent path calls this before SwiftUI receives command keys.
    func handleBarCommandShortcut(_ event: NSEvent) -> Bool {
        guard barController?.window?.isKeyWindow == true else { return false }

        let flags = event.modifierFlags
        guard flags.contains(.command), flags.contains(.shift),
              !flags.contains(.control), !flags.contains(.option) else { return false }

        switch Int(event.keyCode) {
        case kVK_ANSI_S:
            showSettings()
            return true
        case kVK_ANSI_P:
            toggleClipBarPause()
            return true
        case kVK_ANSI_T:
            cycleTypeFilter()
            return true
        default:
            return false
        }
    }

    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Events belonging to a native context menu, editor, alert, or the
        // Settings window must stay with their own responder chain. The bar
        // monitor is only responsible for keys delivered to the panel itself.
        guard event.window === barController?.window else { return event }

        if handleBarCommandShortcut(event) { return nil }

        let code = Int(event.keyCode)
        let flags = event.modifierFlags
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)
        let opt = flags.contains(.option)

        if let digit = Self.quickPasteDigit(for: code),
           includes(Settings.shared.quickPasteModifier, in: flags) {
            let items = store.visibleItems
            if digit <= items.count {
                let plain = includes(Settings.shared.plainTextModifier, in: flags)
                    && Settings.shared.plainTextModifier != Settings.shared.quickPasteModifier
                pasteItem(items[digit - 1], asPlainText: plain)
            }
            return nil
        }

        switch code {
        case kVK_Escape:
            if !store.multiSelectedIDs.isEmpty {
                store.clearMultiSelection()
            } else if !store.searchText.isEmpty {
                store.searchText = ""; store.selectFirst()
                searchClearedAt = Date()
            } else { hideBar() }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            pasteSelected(); return nil
        case kVK_LeftArrow, kVK_UpArrow:
            store.moveSelection(by: -1); return nil
        case kVK_RightArrow, kVK_DownArrow:
            store.moveSelection(by: 1); return nil
        case kVK_Delete:
            if cmd { deleteEffectiveSelection(); return nil }
            if !store.searchText.isEmpty {
                store.searchText.removeLast(); store.selectFirst()
                if store.searchText.isEmpty { searchClearedAt = Date() }
                return nil
            }
            // A bare Backspace deletes the selected clip, but only as a
            // deliberate, separate keypress. Auto-repeat is ignored - a held
            // Backspace that just finished clearing a query must not start
            // deleting clips at the key-repeat rate - and a short cooldown
            // after the search empties separates "clear the query" from
            // "delete a clip". There is no undo, and deletions replicate to
            // other devices when sync is on.
            if !event.isARepeat,
               Date().timeIntervalSince(searchClearedAt) > Self.deleteAfterSearchClearCooldown {
                deleteEffectiveSelection()
            }
            return nil
        case kVK_ForwardDelete:
            deleteEffectiveSelection()
            return nil
        default:
            break
        }

        if !cmd && !ctrl && !opt,
           let chars = event.characters, chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 32, scalar.value != 127 {
            store.searchText.append(chars)
            store.selectFirst()
            return nil
        }
        return event
    }

    private static func quickPasteDigit(for keyCode: Int) -> Int? {
        switch keyCode {
        case kVK_ANSI_1, kVK_ANSI_Keypad1: return 1
        case kVK_ANSI_2, kVK_ANSI_Keypad2: return 2
        case kVK_ANSI_3, kVK_ANSI_Keypad3: return 3
        case kVK_ANSI_4, kVK_ANSI_Keypad4: return 4
        case kVK_ANSI_5, kVK_ANSI_Keypad5: return 5
        case kVK_ANSI_6, kVK_ANSI_Keypad6: return 6
        case kVK_ANSI_7, kVK_ANSI_Keypad7: return 7
        case kVK_ANSI_8, kVK_ANSI_Keypad8: return 8
        case kVK_ANSI_9, kVK_ANSI_Keypad9: return 9
        default: return nil
        }
    }

    private func includes(_ carbonModifier: Int, in flags: NSEvent.ModifierFlags) -> Bool {
        switch carbonModifier {
        case cmdKey: return flags.contains(.command)
        case optionKey: return flags.contains(.option)
        case controlKey: return flags.contains(.control)
        case shiftKey: return flags.contains(.shift)
        default: return false
        }
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
