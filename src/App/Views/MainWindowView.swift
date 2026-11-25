import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case proxy = "代理概览"
    case monitor = "实时监控"
    case usage = "用量与账单"
    case plugin = "应用内插件"
    case settings = "高级设置"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .proxy: return "network.badge.shield.half.filled"
        case .monitor: return "gauge.with.dots.needle.33percent"
        case .usage: return "chart.bar.xaxis"
        case .plugin: return "puzzlepiece.extension.fill"
        case .settings: return "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .proxy: return .blue
        case .monitor: return .teal
        case .usage: return .indigo
        case .plugin: return .purple
        case .settings: return .gray
        }
    }

    func title(_ lang: AppLanguage) -> String {
        switch self {
        case .proxy: return L10n.t("代理概览", "Proxy Overview", lang)
        case .monitor: return L10n.t("实时监控", "Live Monitor", lang)
        case .usage: return L10n.t("用量与账单", "Usage & Billing", lang)
        case .plugin: return L10n.t("应用内插件", "In-App Plugin", lang)
        case .settings: return L10n.t("高级设置", "Settings", lang)
        }
    }

    func subtitle(_ lang: AppLanguage) -> String {
        switch self {
        case .proxy:
            return L10n.t(
                "三通道免 TUN 代理、实时健康链路与 Runtime 副本启动",
                "3-channel TUN-free proxy, live health chain & runtime launcher",
                lang
            )
        case .monitor:
            return L10n.t(
                "直连本地 Language Server 查看实时上下文构成与配额池",
                "Inspect live session context & model quota pools via local Language Server",
                lang
            )
        case .usage:
            return L10n.t(
                "20 周 Token 活跃热力图、每日趋势与估算 API 账单",
                "20-week token heatmap, daily trend & estimated API billing",
                lang
            )
        case .plugin:
            return L10n.t(
                "将实时监控与账单看板直接嵌入 Antigravity 应用内部",
                "Embed live telemetry & billing dashboard directly inside Antigravity",
                lang
            )
        case .settings:
            return L10n.t(
                "界面语言、NO_PROXY 绕过规则、菜单栏常驻伴侣与副本维护",
                "Language, NO_PROXY bypass rules, menu bar companion & maintenance",
                lang
            )
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var monitorStore: MonitorStore
    @ObservedObject var updateStore: UpdateStore
    var onHideToMenuBar: () -> Void

    private static let sidebarCollapsedKey = "pilot.sidebarCollapsed"

    @State private var selectedTab: MainTab = .proxy
    @State private var hoveredTab: MainTab?
    @State private var hoveredHeaderButton: String?
    @State private var showHelpPopover = false
    @State private var showUpdatePopover = false
    @State private var isHoveringVersion = false
    @State private var isSidebarCollapsed: Bool = UserDefaults.standard.bool(forKey: "pilot.sidebarCollapsed")

    private var lang: AppLanguage {
        appModel.config.appLanguage
    }

    private var hasActionableUpdate: Bool {
        updateStore.hasActionableUpdate(skippedVersion: appModel.config.skippedUpdateVersion)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 204)
                .frame(maxHeight: .infinity)
                .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))
                .offset(x: isSidebarCollapsed ? -24 : 0)
                .opacity(isSidebarCollapsed ? 0 : 1)
                .frame(width: isSidebarCollapsed ? 0 : 204, alignment: .trailing)
                .clipped()
                .allowsHitTesting(!isSidebarCollapsed)
                .accessibilityHidden(isSidebarCollapsed)

            Divider()
                .opacity(isSidebarCollapsed ? 0 : 1)
                .frame(width: isSidebarCollapsed ? 0 : 1)

            ZStack {
                PilotAmbientBackdrop(tint: selectedTab.tint)

                VStack(spacing: 0) {
                    contentHeader
                    Divider().opacity(0.6)

                    Group {
                        switch selectedTab {
                        case .proxy:
                            ProxyConfigView(
                                appModel: appModel,
                                onHideToMenuBar: onHideToMenuBar,
                                onOpenTab: { selectedTab = $0 }
                            )
                        case .monitor:
                            MonitorDashboardView(appModel: appModel, monitorStore: monitorStore)
                        case .usage:
                            UsageHeatmapView(monitorStore: monitorStore)
                        case .plugin:
                            InAppPluginView(appModel: appModel)
                        case .settings:
                            AdvancedSettingsView(appModel: appModel, onHideToMenuBar: onHideToMenuBar)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .environment(\.appLanguage, lang)
        .frame(width: 820, height: 590)
        .onAppear {
            monitorStore.setInteractiveVisible(true)
        }
        .onChange(of: isSidebarCollapsed) { collapsed in
            UserDefaults.standard.set(collapsed, forKey: Self.sidebarCollapsedKey)
        }
        .onChange(of: updateStore.openPopoverRequestCount) { _ in
            if isSidebarCollapsed {
                withAnimation(.easeInOut(duration: 0.22)) {
                    isSidebarCollapsed = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    showUpdatePopover = true
                }
            } else {
                showUpdatePopover = true
            }
            if !updateStore.state.isBusy,
               updateStore.availableVersionBadgeText(skippedVersion: appModel.config.skippedUpdateVersion) == nil {
                updateStore.checkForUpdates(config: appModel.config, userInitiated: true)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Brand header below macOS traffic lights
            HStack(spacing: 10) {
                Image(nsImage: appModel.pilotAppIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Antigravity Pilot")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(runtimeDotColor)
                            .frame(width: 6, height: 6)

                        Button {
                            showUpdatePopover.toggle()
                            if showUpdatePopover {
                                switch updateStore.state {
                                case .idle, .failed:
                                    updateStore.checkForUpdates(config: appModel.config, userInitiated: true)
                                default:
                                    break
                                }
                            }
                        } label: {
                            Text("v\(appModel.appVersionText)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(isHoveringVersion ? .primary : .secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(isHoveringVersion || showUpdatePopover ? Color.primary.opacity(0.08) : Color.clear)
                                )
                                .overlay(alignment: .topTrailing) {
                                    if hasActionableUpdate {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 6.5, height: 6.5)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: 1)
                                            )
                                            .offset(x: 2, y: -2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isHoveringVersion = hovering
                        }
                        .help(versionButtonTooltip)
                        .popover(isPresented: $showUpdatePopover, arrowEdge: .trailing) {
                            UpdatePopoverView(appModel: appModel, updateStore: updateStore)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 36)

            // Navigation items
            VStack(spacing: 4) {
                ForEach(MainTab.allCases) { tab in
                    sidebarItem(tab)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            // Bottom Mini-Telemetry Card
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTab = .monitor
                }
            } label: {
                PilotRecessedBox(padding: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(healthDotColor)
                                .frame(width: 7, height: 7)
                            Text(appModel.healthReport.summaryTitle)
                                .font(.caption.weight(.semibold))
                                .fontDesign(.rounded)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                        }

                        HStack(spacing: 5) {
                            Image(systemName: monitorStore.liveHub != nil ? "bolt.horizontal.fill" : "moon.zzz")
                                .font(.caption2)
                                .foregroundStyle(monitorStore.liveHub != nil ? .teal : .secondary)
                            Text(monitorStore.compactMenuBarText ?? L10n.t("等待 Antigravity 运行", "Waiting for Antigravity", lang))
                                .font(.caption2)
                                .fontDesign(.rounded)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .help(L10n.t("点击查看实时监控", "Click to view Live Monitor", lang))

            // Bottom action button
            HStack {
                if appModel.config.enableMenuBarMonitor {
                    Button {
                        onHideToMenuBar()
                    } label: {
                        Label(L10n.t("缩入菜单栏", "Minimize to Menu Bar", lang), systemImage: "menubar.arrow.up.rectangle")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label(L10n.t("退出 Pilot", "Quit Pilot", lang), systemImage: "power")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
    }

    private func sidebarItem(_ tab: MainTab) -> some View {
        let isSelected = selectedTab == tab
        let isHovered = hoveredTab == tab

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : tab.tint)
                    .frame(width: 22, height: 22)
                    .background(isSelected ? tab.tint : tab.tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(tab.title(lang))
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()

                if tab == .plugin {
                    pluginSidebarBadge
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.primary.opacity(0.09)
                            : (isHovered ? Color.primary.opacity(0.045) : Color.clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
        }
    }

    @ViewBuilder
    private var pluginSidebarBadge: some View {
        switch appModel.mcpPluginStatus {
        case .updateAvailable:
            Circle()
                .fill(Color.orange)
                .frame(width: 6.5, height: 6.5)
        case .installedCurrent:
            Circle()
                .fill(Color.green)
                .frame(width: 6.5, height: 6.5)
        default:
            EmptyView()
        }
    }

    private var contentHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            headerIconButton(
                id: "sidebar",
                systemName: "sidebar.left",
                isActive: false,
                symbolSize: 12,
                help: isSidebarCollapsed
                    ? L10n.t("展开侧边栏 (⌥⌘S)", "Show Sidebar (⌥⌘S)", lang)
                    : L10n.t("收起侧边栏 (⌥⌘S)", "Hide Sidebar (⌥⌘S)", lang)
            ) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    isSidebarCollapsed.toggle()
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSidebarCollapsed && hasActionableUpdate {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6.5, height: 6.5)
                        .offset(x: 2, y: -2)
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedTab.title(lang))
                    .font(.title3.weight(.semibold))
                Text(selectedTab.subtitle(lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSidebarCollapsed {
                HStack(spacing: 5) {
                    ForEach(MainTab.allCases) { tab in
                        let isSelected = selectedTab == tab
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        } label: {
                            Image(systemName: tab.symbolName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(isSelected ? .white : tab.tint)
                                .frame(width: 24, height: 24)
                                .background(isSelected ? tab.tint : tab.tint.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(tab.title(lang))
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
            }

            if selectedTab == .proxy {
                headerIconButton(
                    id: "help",
                    systemName: "questionmark.circle",
                    isActive: showHelpPopover,
                    symbolSize: 12.5,
                    help: L10n.t("查看使用说明", "View tips", lang)
                ) {
                    showHelpPopover.toggle()
                }
                .popover(isPresented: $showHelpPopover, arrowEdge: .bottom) {
                    helpPopover
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func headerIconButton(
        id: String,
        systemName: String,
        isActive: Bool,
        symbolSize: CGFloat,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredHeaderButton == id
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : (isHovered ? .primary : .secondary))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isActive
                                ? Color.accentColor.opacity(0.14)
                                : (isHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.06))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.09),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            hoveredHeaderButton = hovering ? id : (hoveredHeaderButton == id ? nil : hoveredHeaderButton)
        }
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("Antigravity Pilot 使用提示", "Antigravity Pilot Tips", lang), systemImage: "lightbulb.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                helpBullet(L10n.t(
                    "Dock 单图标秒开：首次启动 Pilot 后，右键 Dock 上运行中的图标 →「选项 → 在程序坞中保留」，日常即可秒开。",
                    "Keep in Dock: Right-click the running icon in Dock → Options → Keep in Dock for one-click launch.",
                    lang
                ))
                helpBullet(L10n.t(
                    "0.1s 免重建热更新：仅修改代理端口、协议或 NO_PROXY 列表时，将直接写入外置 proxy.env，无需重复复制或重签名。",
                    "0.1s Hot Update: Changing ports, scheme, or NO_PROXY updates external proxy.env directly without copying or re-signing.",
                    lang
                ))
                helpBullet(L10n.t(
                    "零入侵原版应用：/Applications/Antigravity.app 始终保持只读不改动；开启顶部菜单栏图标时，关闭本窗口后监控缩入菜单栏。",
                    "Non-invasive: /Applications/Antigravity.app remains untouched; when the menu bar icon is enabled, closing this window minimizes monitoring to the menu bar.",
                    lang
                ))
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private func helpBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var versionButtonTooltip: String {
        if let ver = updateStore.availableVersionBadgeText(skippedVersion: appModel.config.skippedUpdateVersion) {
            return L10n.t(
                zhHans: "发现新版本 v\(ver)，点击查看并更新",
                zhHant: "發現新版本 v\(ver)，點擊查看並更新",
                en: "Update v\(ver) available — click to view",
                ru: "Доступно обновление v\(ver) — нажмите для просмотра",
                lang
            )
        }
        return L10n.t("点击检查软件更新", "Click to check for updates", lang)
    }

    private var runtimeDotColor: Color {
        switch appModel.runtimeStatusKind {
        case .ready: return .green
        case .updateNeeded: return .orange
        case .notBuilt: return .secondary
        case .missingSource: return .red
        }
    }

    private var healthDotColor: Color {
        switch appModel.healthReport.level {
        case .checking: return .secondary
        case .healthy: return .green
        case .degraded: return .orange
        case .failed: return .red
        }
    }
}

extension View {
    @ViewBuilder
    func applyPulseSymbolEffect(_ active: Bool) -> some View {
        if #available(macOS 14, *), active {
            self.symbolEffect(.pulse)
        } else {
            self
        }
    }
}
