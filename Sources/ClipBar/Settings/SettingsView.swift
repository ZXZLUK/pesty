import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(L10n.t("General", "通用"), systemImage: "gearshape") }
            PrivacySettings()
                .tabItem { Label(L10n.t("Privacy", "隐私"), systemImage: "hand.raised") }
            AboutView()
                .tabItem { Label(L10n.t("About", "关于"), systemImage: "info.circle") }
        }
        .frame(width: 520, height: 560)
    }
}

private struct PrivacySettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Section(L10n.t("Excluded Apps", "排除的应用")) {
                Text(L10n.t("ClipBar will not save anything copied while one of these apps is frontmost. Copies made from a browser extension are attributed to the browser, so add that too if you use one.",
                            "ClipBar 不会保存这些应用处于前台时复制的内容。浏览器扩展的复制会被归因到浏览器本身，如果你在用扩展，请把浏览器也加上。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.ignoredSourceAppBundleIDs.isEmpty {
                    ContentUnavailableView(L10n.t("No apps excluded", "暂无排除的应用"),
                                           systemImage: "hand.raised",
                                           description: Text(L10n.t("Add an app to keep its copied content out of ClipBar.",
                                                                    "添加一个应用，让它复制的内容不进入 ClipBar。")))
                        .padding(.vertical, 12)
                } else {
                    ForEach(settings.ignoredSourceAppBundleIDs, id: \.self) { bundleID in
                        ignoredAppRow(bundleID)
                    }
                }

                Button { chooseApps() } label: {
                    Label(L10n.t("Add App…", "添加应用…"), systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func ignoredAppRow(_ bundleID: String) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconProvider.icon(forBundleID: bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(applicationName(for: bundleID))
                    .font(.system(size: 13, weight: .medium))
                Text(bundleID)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.removeIgnoredSourceApp(bundleID) } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("Allow clips from \(applicationName(for: bundleID))",
                         "恢复记录 \(applicationName(for: bundleID)) 的复制内容"))
        }
        .padding(.vertical, 4)
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("Exclude Apps from ClipBar", "从 ClipBar 排除应用")
        panel.message = L10n.t("ClipBar will ignore copied content from the apps you choose.",
                               "ClipBar 将忽略你选择的这些应用复制的内容。")
        panel.prompt = L10n.t("Add Apps", "添加")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            settings.addIgnoredSourceApp(bundleID)
        }
    }

    private func applicationName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return bundleID }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleID
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = Settings.shared
    #if !MAS
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var requestedGrant = false

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    #endif

    var body: some View {
        Form {
            Section(L10n.t("Activation", "呼出")) {
                LabeledContent(L10n.t("Show ClipBar", "打开 ClipBar")) { HotkeyRecorderView() }
            }

            HistoryRetentionSettings()

            Section(L10n.t("Quick Paste", "快速粘贴")) {
                LabeledContent(L10n.t("Paste items 1–9", "粘贴第 1–9 项")) {
                    HStack(spacing: 6) {
                        modifierPicker(selection: $settings.quickPasteModifier)
                        Text("+ 1…9").foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L10n.t("Paste as plain text", "粘贴为纯文本")) {
                    modifierPicker(selection: $settings.plainTextModifier)
                }
                Text(L10n.t("Hold the plain-text modifier while using Quick Paste to strip formatting — with the defaults, ⌘⇧1 pastes the first clip as plain text. The two roles can never share a modifier; picking one that is taken swaps them.",
                            "快速粘贴时按住纯文本修饰键可去掉格式——默认设置下 ⌘⇧1 会以纯文本粘贴第一项。两个修饰键不能相同；选择已被占用的修饰键会自动互换。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("Behavior", "行为")) {
                #if !MAS
                Toggle(L10n.t("Paste directly into the active app", "直接粘贴到当前应用"), isOn: $settings.pasteDirectly)
                #endif
                Toggle(L10n.t("Ignore passwords (concealed clips)", "忽略密码（隐藏类型的复制）"), isOn: $settings.ignoreConcealed)
                Toggle(L10n.t("Play sound on paste", "粘贴时播放音效"), isOn: $settings.playSound)
                Toggle(L10n.t("Hide ClipBar when clicking outside", "点击外部时收起 ClipBar"), isOn: $settings.hideOnClickOutside)
                Toggle(L10n.t("Launch at login", "登录时自动启动"), isOn: $settings.launchAtLogin)
                Toggle(L10n.t("Show ClipBar in the menu bar", "在菜单栏显示 ClipBar 图标"), isOn: $settings.showMenuBarIcon)
                VStack(alignment: .leading) {
                    LabeledContent(L10n.t("Bar height", "卡片条高度"), value: "\(Int(settings.barHeight)) px")
                    Slider(value: $settings.barHeight, in: 300...720, step: 10)
                }
                #if MAS
                Text(L10n.t("Select a clip to copy it, then press ⌘V to paste it into your app.",
                            "选择一条内容完成复制，然后按 ⌘V 粘贴到你的应用里。"))
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }

            #if MAS
            Section(L10n.t("Sync", "同步")) {
                Toggle(L10n.t("Sync history with iCloud", "通过 iCloud 同步历史"), isOn: Binding(
                    get: { settings.cloudKitSync },
                    set: { on in
                        settings.cloudKitSync = on
                        if on { CloudSyncService.shared.enable() } else { CloudSyncService.shared.stop() }
                    }))
                Text(CloudSyncService.shared.status)
                    .font(.caption).foregroundStyle(.secondary)
            }
            #else
            Section(L10n.t("Sync", "同步")) {
                Text(L10n.t("Multi-Mac sync is temporarily unavailable while storage moves to the new database. History stays on this Mac.",
                            "多设备同步在存储迁移到新数据库期间暂不可用。历史数据只保存在本机。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            #if !MAS
            Section(L10n.t("Permissions", "权限")) {
                HStack(spacing: 10) {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("Accessibility", "辅助功能"))
                        Text(accessibilityGranted
                             ? L10n.t("Granted — direct paste is enabled.", "已授权——直接粘贴可用。")
                             : (requestedGrant
                                ? L10n.t("Waiting… toggle ClipBar on in System Settings.", "等待中……请在系统设置里打开 ClipBar 的开关。")
                                : L10n.t("Required to paste directly into other apps.", "直接粘贴到其他应用需要此权限。")))
                            .font(.caption)
                            .foregroundStyle(accessibilityGranted ? .green : .secondary)
                    }
                    Spacer()
                    if !accessibilityGranted {
                        Button(L10n.t("Open Settings", "打开系统设置")) {
                            requestedGrant = true
                            PasteService.ensureAccessibility(prompt: true)
                            openAccessibilityPane()
                        }
                    } else if requestedGrant {
                        Button(L10n.t("Restart ClipBar", "重启 ClipBar")) { AppController.restart() }
                    }
                }
            }
            #endif

            Section(L10n.t("Data", "数据")) {
                Button(L10n.t("Clear Clipboard History", "清空剪贴板历史"), role: .destructive) {
                    ClipboardStore.shared.clearHistory()
                }
            }
        }
        .formStyle(.grouped)
        #if !MAS
        .onAppear { accessibilityGranted = AXIsProcessTrusted() }
        .onReceive(poll) { _ in
            let now = AXIsProcessTrusted()
            if now != accessibilityGranted { accessibilityGranted = now }
        }
        #endif
    }

    #if !MAS
    private func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    #endif

    private func modifierPicker(selection: Binding<Int>) -> some View {
        Picker("", selection: selection) {
            ForEach(ShortcutModifier.allCases) { modifier in
                Text("\(modifier.symbol) \(L10n.t(modifier.title, modifier.titleZH))").tag(modifier.carbonValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 118)
    }
}

private struct HistoryRetentionSettings: View {
    private var settings = Settings.shared
    @State private var draftMode = Settings.shared.historyRetentionMode
    @State private var draftLimit = Settings.shared.historyLimit
    @State private var draftDays = Settings.shared.historyRetentionDays
    @State private var pendingRemovalCount = 0
    @State private var confirmingChange = false

    private static let dayChoices: [(days: Int, label: String, labelZH: String)] = [
        (1, "1 Day", "1 天"), (7, "1 Week", "1 周"), (14, "2 Weeks", "2 周"), (30, "1 Month", "1 个月"),
        (90, "3 Months", "3 个月"), (180, "6 Months", "6 个月"), (365, "1 Year", "1 年")
    ]

    var body: some View {
        Section(L10n.t("History", "历史记录")) {
            Picker(L10n.t("Limit history by", "限制方式"), selection: $draftMode) {
                ForEach(HistoryRetentionMode.allCases) { mode in
                    Text(mode.titleZH).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            if draftMode == .itemCount {
                Stepper(value: $draftLimit, in: 50...5000, step: 50) {
                    LabeledContent(L10n.t("Keep at most", "最多保留"), value: L10n.t("\(draftLimit) clips", "\(draftLimit) 条"))
                }
            } else {
                Picker(L10n.t("Remove clips older than", "清除超过以下时长的内容"), selection: $draftDays) {
                    ForEach(Self.dayChoices, id: \.days) { choice in
                        Text(L10n.t(choice.label, choice.labelZH)).tag(choice.days)
                    }
                }
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: draftMode) { evaluateDraft() }
        .onChange(of: draftLimit) { evaluateDraft() }
        .onChange(of: draftDays) { evaluateDraft() }
        .alert(L10n.t("Remove \(pendingRemovalCount) Clips?", "移除 \(pendingRemovalCount) 条内容？"), isPresented: $confirmingChange) {
            Button(L10n.t("Remove \(pendingRemovalCount) Clips", "移除 \(pendingRemovalCount) 条"), role: .destructive) { commit() }
            Button(L10n.t("Cancel", "取消"), role: .cancel) { revert() }
        } message: {
            Text(L10n.t("This setting removes \(pendingRemovalCount) clips from history on this Mac now, and keeps pruning automatically. Pinboards are not affected, and there is no undo.",
                        "此设置会立即从这台 Mac 的历史中移除 \(pendingRemovalCount) 条内容，并持续自动清理。Pinboard 不受影响，且无法撤销。"))
        }
    }

    private var footnote: String {
        #if MAS
        L10n.t("Pruning tidies this Mac only — synced copies stay on your other devices. Pinned clips are never removed.",
               "清理只影响本机——其他设备上的同步副本保留。Pin 住的内容永不被清除。")
        #else
        L10n.t("Pruning applies to this Mac's history. Pinned clips are never removed.",
               "清理只影响本机历史。Pin 住的内容永不被清除。")
        #endif
    }

    private func evaluateDraft() {
        let count = ClipboardStore.shared.retentionRemovalCount(
            mode: draftMode, limit: draftLimit, days: draftDays)
        if count > 0 {
            pendingRemovalCount = count
            confirmingChange = true
        } else {
            commit()
        }
    }

    private func commit() {
        settings.historyRetentionMode = draftMode
        settings.historyLimit = draftLimit
        settings.historyRetentionDays = draftDays
        ClipboardStore.shared.applyRetentionPolicy()
    }

    private func revert() {
        draftMode = settings.historyRetentionMode
        draftLimit = settings.historyLimit
        draftDays = settings.historyRetentionDays
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().frame(width: 88, height: 88)
            Text("ClipBar").font(.system(size: 26, weight: .bold))
            Text(L10n.t("Version \(Bundle.main.appVersion)", "版本 \(Bundle.main.appVersion)"))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(L10n.t("A free, open-source clipboard manager for macOS.",
                        "macOS 上的免费开源剪贴板管理器。"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack(spacing: 16) {
                Link(L10n.t("GitHub", "GitHub 仓库"), destination: URL(string: "https://github.com/ZXZLUK/clipbar")!)
                Link(L10n.t("Report an Issue", "反馈问题"), destination: URL(string: "https://github.com/ZXZLUK/clipbar/issues")!)
            }
            .padding(.top, 4)
            Button(L10n.t("Quit ClipBar", "退出 ClipBar"), role: .destructive) {
                NSApp.terminate(nil)
            }
            .padding(.top, 8)
            Spacer()
            Text(L10n.t("MIT Licensed · Made with SwiftUI", "MIT 许可 · 基于 SwiftUI"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
