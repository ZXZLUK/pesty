import SwiftUI

struct BarView: View {
    @Bindable private var store = ClipboardStore.shared
    @Bindable private var settings = Settings.shared

    var body: some View {
        ZStack {
            panelBackground
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                topBar
                strip
            }
        }
        .clipShape(RoundedCorners(radius: Theme.cornerRadius, corners: [.topLeft, .topRight]))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var panelBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            VisualEffectView(material: .hudWindow)
            Theme.panelTint
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            typeFilterMenu
            quickFilter(.image)
            quickFilter(.file)
            if let hint = store.deletionHint {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.chromeTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.pillBG, in: Capsule())
                    .help(L10n.t("Press ⌘Z to undo", "按 ⌘Z 撤销"))
            }
            searchIndicator
            PinboardTabs()
                .layoutPriority(1)
            Spacer(minLength: 8)
            if store.multiSelectedIDs.count > 1 {
                bulkDeleteButton
            }
            agentControls
            moreMenu
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    /// Type filter (⌘⇧T cycles): 全部 / 文本 / 富文本 / 链接 / 图片 / 文件 / 颜色.
    private var typeFilterMenu: some View {
        Menu {
            Button(L10n.t("All Types", "全部类型")) { store.typeFilter = nil }
            ForEach(ClipType.allCases, id: \.rawValue) { t in
                Button {
                    store.typeFilter = store.typeFilter == t ? nil : t
                } label: {
                    if store.typeFilter == t {
                        Label(t.label, systemImage: "checkmark")
                    } else {
                        Text(t.label)
                    }
                }
            }
        } label: {
            Image(systemName: store.typeFilter?.symbol ?? "line.3.horizontal.decrease.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(store.typeFilter == nil ? Theme.chromeTextSecondary : Theme.selection)
        }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(L10n.t("Filter by type (⌘⇧T cycles)", "按类型过滤（⌘⇧T 循环切换）"))
}

/// Dedicated one-tap filters for the two types reached for most; every other
/// type stays in the funnel menu. Tap toggles — typeFilter is a single value,
/// so picking one pill clears the other.
private func quickFilter(_ type: ClipType) -> some View {
    let active = store.typeFilter == type
    return Button {
        store.typeFilter = store.typeFilter == type ? nil : type
    } label: {
        HStack(spacing: 5) {
            Image(systemName: type.symbol)
                .font(.system(size: 12, weight: .medium))
            Text(type.label)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(active ? Theme.selection : Theme.chromeTextSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.selection.opacity(active ? 0.16 : 0), in: Capsule())
    }
    .buttonStyle(.plain)
    .help(L10n.t("Show only \(type.label)", "只看\(type.label)"))
}

    private var searchIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(store.searchText.isEmpty ? Theme.chromeTextSecondary : Theme.chromeTextPrimary)
            if !store.searchText.isEmpty {
                Text(store.searchText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.chromeTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button { store.searchText = ""; store.selectFirst() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.chromeTextTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, store.searchText.isEmpty ? 0 : 10)
        .frame(minWidth: 22, maxWidth: 700, minHeight: 30, maxHeight: 30, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(store.searchText.isEmpty ? Color.clear : Theme.fieldBG, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: store.searchText.isEmpty)
    }

    private var bulkDeleteButton: some View {
        let count = store.multiSelectedIDs.count
        return Button(role: .destructive) {
            AppController.shared.deleteEffectiveSelection()
        } label: {
            Label("Delete \(count)", systemImage: "trash")
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Delete \(count) selected clips (⌘⌫)")
        .accessibilityLabel("Delete \(count) selected clips")
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.t("Settings…", "设置…")) { AppController.shared.showSettings() }
            Button(L10n.t("Clear History", "清空历史")) { store.clearHistory() }
            Divider()
            Button(L10n.t("About ClipBar", "关于 ClipBar")) { AppController.shared.showAbout() }
            Button(L10n.t("Quit ClipBar", "退出 ClipBar")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.chromeTextSecondary)
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34)
        .fixedSize()
    }

    /// Clipboard Agent 的主控面：总开关负责“是否允许自动调用模型”，
    /// preset 只在开启时出现，避免 OFF 状态仍给人“正在处理”的错觉。
    private var agentControls: some View {
        HStack(spacing: 6) {
            agentToggle
            if settings.subtitleTriggerEnabled {
                agentPresetMenu
            }
        }
    }

    private var agentToggle: some View {
        let on = settings.subtitleTriggerEnabled
        return Button {
            settings.subtitleTriggerEnabled.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(on ? Theme.selection : Theme.chromeTextSecondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                Text("Podcast Agent")
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.selection : Theme.chromeTextSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(on ? Theme.selection.opacity(0.16) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.t(on ? "Podcast Agent is ON — new subtitles and long text may compile automatically" : "Podcast Agent is OFF — no automatic model calls",
                     on ? "Podcast Agent 已开启——新字幕和长文本可自动编译" : "Podcast Agent 已关闭——不会自动调用模型"))
    }

    private var agentPresetMenu: some View {
        Menu {
            ForEach(AgentCompilerPreset.allCases) { preset in
                Button {
                    settings.agentCompilerPreset = preset
                } label: {
                    if settings.agentCompilerPreset == preset {
                        Label(L10n.t(preset.title, preset.titleZH), systemImage: "checkmark")
                    } else {
                        Text(L10n.t(preset.title, preset.titleZH))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(L10n.t(settings.agentCompilerPreset.title, settings.agentCompilerPreset.titleZH))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.chromeTextSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.pillBG, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("Choose how Podcast Agent compiles the next content", "选择 Podcast Agent 的编译形态"))
    }

    /// Identifies the padded scroll content, so a presentation reset can land
    /// on the strip's natural resting offset - anchoring the first card's
    /// leading edge instead would scroll the horizontal inset out of view.
    private static let stripStartID = "stripStart"

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.cardSpacing) {
                    ForEach(Array(store.visibleItems.enumerated()), id: \.element.id) { index, item in
                        ClipCardView(item: item,
                                     index: index,
                                     selected: store.isSelected(item.id))
                            .id(item.id)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.92).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                .padding(.horizontal, Theme.cardStripHorizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .animation(.spring(response: 0.34, dampingFraction: 0.8), value: store.visibleItems.count)
                .id(Self.stripStartID)
            }
            .onChange(of: store.barPresentationToken) { _, _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(Self.stripStartID, anchor: .leading)
                }
            }
            .onChange(of: store.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .overlay { if store.visibleItems.isEmpty { emptyState } }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.chromeTextTertiary)
            Text(store.searchText.isEmpty
                 ? L10n.t("Nothing copied yet", "还没有复制过内容")
                 : L10n.t("No matches for “\(store.searchText)”", "没有匹配“\(store.searchText)”的结果"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.chromeTextSecondary)
        }
    }
}

struct RoundedCorners: Shape {
    var radius: CGFloat
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
}
