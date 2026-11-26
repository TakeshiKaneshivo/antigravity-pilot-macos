import AppKit
import SwiftUI

struct ProxyConfigView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var appModel: AppModel
    @ObservedObject var antigravityUpdateStore: AntigravityUpdateStore
    var onHideToMenuBar: () -> Void
    var onOpenTab: (MainTab) -> Void

    private enum AntigravityCheckPopover: Equatable {
        case error
        case upToDateNeedsRebuild
    }

    @State private var showHealthPopover = false
    @State private var activeAntigravityPopover: AntigravityCheckPopover?
    @State private var showProxyDefaultsTipPopover = false
    @State private var isHoveringProxyTip = false

    private var isBusy: Bool {
        appModel.isWorking || antigravityUpdateStore.state.isBusy
    }

    private struct PortPreset: Identifiable {
        let id: String
        let shortTitle: String
        let title: String
        let hookPort: Int
        let envScheme: String
        let envPort: Int
    }

    private let portPresets: [PortPreset] = [
        PortPreset(id: "clash-7890", shortTitle: "Clash 7890", title: "Clash / Mihomo Mixed (7890)", hookPort: 7890, envScheme: "http", envPort: 7890),
        PortPreset(id: "verge-7897", shortTitle: "Verge 7897", title: "Clash Verge (7897)", hookPort: 7897, envScheme: "http", envPort: 7897),
        PortPreset(id: "clash-7891", shortTitle: "Clash 7891", title: "Clash SOCKS5 (7891)", hookPort: 7891, envScheme: "socks5", envPort: 7891),
        PortPreset(id: "surge-6153", shortTitle: "Surge 6153", title: "Surge (6153 / 6152)", hookPort: 6153, envScheme: "http", envPort: 6152),
        PortPreset(id: "v2ray-10808", shortTitle: "v2ray 10808", title: "v2rayN / Xray (10808 / 10809)", hookPort: 10808, envScheme: "http", envPort: 10809),
        PortPreset(id: "singbox-12334", shortTitle: "Sing-box 12334", title: "Hiddify / Sing-box (12334)", hookPort: 12334, envScheme: "http", envPort: 12334),
        PortPreset(id: "socks-1080", shortTitle: "SOCKS 1080", title: "Local SOCKS5 (1080)", hookPort: 1080, envScheme: "socks5", envPort: 1080)
    ]

    private var selectedPreset: PortPreset? {
        portPresets.first(where: {
            $0.hookPort == appModel.config.hookPort
                && $0.envScheme == appModel.config.envScheme
                && $0.envPort == appModel.config.envPort
        })
    }

    private var selectedPresetId: String {
        selectedPreset?.id ?? "custom"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !appModel.runningInstances.isEmpty {
                    runningConflictBanner
                }

                if shouldShowAntigravityUpdateBanner {
                    antigravityUpdateBanner
                }

                heroLaunchCard

                EqualHeightTwoColumnLayout(spacing: 12, trailingWidth: 256) {
                    proxySettingsCard
                        .disabled(isBusy)

                    iconStyleCard
                        .disabled(isBusy)
                }

                quickActionsStrip

                menuBarDisplayCard

                if let error = appModel.errorMessage {
                    messageBanner(error, isError: true)
                } else if let success = appModel.bannerSuccessMessage {
                    messageBanner(success, isError: false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
        }
        .onChange(of: appModel.config.host) { _ in
            appModel.scheduleProxyHealthCheck()
        }
        .onChange(of: appModel.config.hookPort) { _ in
            appModel.scheduleProxyHealthCheck()
        }
        .onChange(of: appModel.config.envPort) { _ in
            appModel.scheduleProxyHealthCheck()
        }
        .onChange(of: appModel.config.runtimeIconStyle) { _ in
            appModel.refreshRuntimeStatus()
        }
        .onChange(of: appModel.config.enableMenuBarMonitor) { _ in
            appModel.savePreferencesOnly()
        }
        .onChange(of: antigravityUpdateStore.state) { newState in
            if case .failed = newState {
                activeAntigravityPopover = .error
            } else {
                switch newState {
                case .checking, .available, .downloading, .verifying, .replacingAndRebuilding:
                    activeAntigravityPopover = nil
                default:
                    if activeAntigravityPopover == .error {
                        activeAntigravityPopover = nil
                    }
                }
            }
        }
        .onChange(of: antigravityUpdateStore.manualUpToDateEventCount) { _ in
            appModel.refreshRuntimeStatus()
            if appModel.runtimeStatusKind == .updateNeeded || appModel.runtimeStatusKind == .notBuilt {
                activeAntigravityPopover = .upToDateNeedsRebuild
            }
        }
    }

    private var heroLaunchCard: some View {
        PilotCard(padding: 12, accentTint: heroAccentTint) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    Image(nsImage: PilotIconCache.baked(
                        appModel.previewIcon,
                        key: "preview-\(appModel.config.runtimeIconStyle.rawValue)",
                        side: 44,
                        cornerRadius: 10,
                        shadowBlur: 6,
                        shadowYOffset: 2,
                        shadowAlpha: 0.14
                    ))
                    .frame(width: 44 + PilotIconCache.margin * 2, height: 44 + PilotIconCache.margin * 2)
                    .padding(-PilotIconCache.margin)
                    .id(appModel.config.runtimeIconStyle)
                    .animation(.easeInOut(duration: 0.15), value: appModel.config.runtimeIconStyle)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(L10n.t("Antigravity Pilot 代理副本", "Antigravity Pilot Runtime", lang))
                                .font(.headline.weight(.semibold))
                            PilotStatusPill(
                                text: appModel.hotUpdateStatus.pillTitle(lang),
                                color: hotUpdatePillColor,
                                showDot: false,
                                systemImage: appModel.canHotUpdate ? "bolt.fill" : "shippingbox"
                            )
                            .help(appModel.hotUpdateStatus.detailReason(lang))
                        }
                        HStack(spacing: 6) {
                            Text(appModel.runtimeSummary)
                                .font(.caption)
                                .foregroundStyle(runtimeSummaryColor)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            antigravityCheckButton
                        }
                    }

                    Spacer()

                    Button {
                        appModel.saveAndStart(
                            forceRebuild: false,
                            terminateRunningFirst: !appModel.runningInstances.isEmpty
                        ) {
                            onHideToMenuBar()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if appModel.isWorking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: appModel.canHotUpdate ? "bolt.fill" : "play.fill")
                                    .font(.caption.weight(.semibold))
                            }
                            Text(primaryButtonTitle)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                }

                Divider()

                HStack(spacing: 10) {
                    PilotHealthChainView(report: appModel.healthReport, config: appModel.config)

                    HStack(spacing: 4) {
                        Button {
                            appModel.checkProxyHealth()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                                .applyPulseSymbolEffect(appModel.healthReport.level == .checking)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(L10n.t("立即重测三阶代理健康", "Re-run 3-stage proxy health probe", lang))

                        Button {
                            let willOpen = !showHealthPopover
                            showHealthPopover = willOpen
                            if willOpen {
                                appModel.checkProxyHealth()
                            }
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(L10n.t("查看三阶诊断详情", "View 3-stage diagnostic details", lang))
                        .popover(isPresented: $showHealthPopover, arrowEdge: .bottom) {
                            healthDetailPopover
                        }
                    }
                }
            }
        }
    }

    private var proxySettingsCard: some View {
        PilotCard(padding: 12, fillHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label(L10n.t("核心代理配置", "Core Proxy Settings", lang), systemImage: "network")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Button {
                        showProxyDefaultsTipPopover.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(
                                showProxyDefaultsTipPopover
                                    ? Color.accentColor
                                    : (isHoveringProxyTip ? .primary : .secondary)
                            )
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringProxyTip = hovering
                    }
                    .help(L10n.t(
                        zhHans: "默认配置说明：多数情况直接使用默认即可",
                        zhHant: "預設設定說明：多數情況直接使用預設即可",
                        en: "Default settings tip: works out of the box for most setups",
                        ru: "Подсказка: обычно достаточно настроек по умолчанию",
                        lang
                    ))
                    .popover(isPresented: $showProxyDefaultsTipPopover, arrowEdge: .bottom) {
                        proxyDefaultsTipPopover
                    }
                }

                VStack(spacing: 6) {
                    configFieldRow(L10n.t("代理 Host", "Proxy Host", lang)) {
                        PilotTextField(placeholder: "127.0.0.1", text: $appModel.config.host)
                    }

                    configFieldRow(L10n.t("SOCKS5 端口", "SOCKS5 Port", lang)) {
                        PilotPortTextField(placeholder: "7890", value: $appModel.config.hookPort)
                    }

                    configFieldRow(L10n.t("ENV 协议", "ENV Scheme", lang)) {
                        PilotSegmentedControl(
                            options: [("http", "http"), ("socks5", "socks5")],
                            selection: $appModel.config.envScheme
                        )
                    }

                    configFieldRow(L10n.t("ENV 端口", "ENV Port", lang)) {
                        PilotPortTextField(placeholder: "7890", value: $appModel.config.envPort)
                    }
                }

                Divider()

                configFieldRow(L10n.t("常用预设", "Presets", lang)) {
                    PilotPresetMenuButton(
                        options: portPresets.map {
                            PilotPresetMenuButton.Option(id: $0.id, shortTitle: $0.shortTitle, fullTitle: $0.title)
                        },
                        selectedId: selectedPresetId,
                        customTitle: L10n.t("自定义", "Custom", lang)
                    ) { newId in
                        if let preset = portPresets.first(where: { $0.id == newId }) {
                            appModel.config.hookPort = preset.hookPort
                            appModel.config.envScheme = preset.envScheme
                            appModel.config.envPort = preset.envPort
                        }
                    }
                }

                Spacer(minLength: 2)

                HStack(spacing: 5) {
                    Image(systemName: "link")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(appModel.config.hookProxyURL)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func configFieldRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            control()
                .frame(maxWidth: .infinity)
        }
    }

    private var proxyDefaultsTipPopover: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(
                L10n.t(
                    zhHans: "默认配置说明",
                    zhHant: "預設設定說明",
                    en: "Default Configuration Tip",
                    ru: "Подсказка по настройке",
                    lang
                ),
                systemImage: "lightbulb.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)

            Divider()

            Text(
                L10n.t(
                    zhHans: "默认配置（127.0.0.1:7890）已适配 Clash / Mihomo 等常见代理工具的默认端口，大多数情况下无需修改即可直接使用。如使用其他代理软件或自定义端口，可在下方「常用预设」中一键切换，或按实际端口手动填写。",
                    zhHant: "預設設定（127.0.0.1:7890）已適配 Clash / Mihomo 等常見代理工具的預設連接埠，大多數情況下無需修改即可直接使用。如使用其他代理軟體或自訂連接埠，可在下方「常用預設」中一鍵切換，或依實際連接埠手動填寫。",
                    en: "The defaults (127.0.0.1:7890) work out of the box for most Clash / Mihomo setups—no changes needed. If you use another proxy client or a custom port, pick one from Presets below or enter your actual port.",
                    ru: "Настройки по умолчанию (127.0.0.1:7890) сразу подходят для большинства клиентов Clash / Mihomo — обычно менять их не нужно. Для других клиентов или портов выберите вариант в «Пресеты» ниже или укажите свой порт.",
                    lang
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(width: 280)
    }

    private var iconStyleCard: some View {
        PilotCard(padding: 12, fillHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.t("应用图标样式", "App Icon Style", lang), systemImage: "app.badge")
                    .font(.subheadline.weight(.semibold))

                VStack(spacing: 6) {
                    iconPreviewRow(
                        cacheKey: "option-badged",
                        title: L10n.t(
                            zhHans: "角标",
                            zhHant: "角標",
                            en: "Badged",
                            ru: "Со значком",
                            lang
                        ),
                        badge: L10n.t(
                            zhHans: "推荐",
                            zhHant: "推薦",
                            en: "Rec.",
                            ru: "Рек.",
                            lang
                        ),
                        caption: L10n.t(
                            zhHans: "三者零撞脸",
                            zhHant: "三者零撞臉",
                            en: "Distinct from both",
                            ru: "Не путается с другими",
                            lang
                        ),
                        image: appModel.badgedRuntimeIcon,
                        selected: appModel.config.runtimeIconStyle == .originalWithBadge
                    ) {
                        appModel.config.runtimeIconStyle = .originalWithBadge
                    }

                    iconPreviewRow(
                        cacheKey: "option-original",
                        title: L10n.t(
                            zhHans: "原版",
                            zhHant: "原版",
                            en: "Original",
                            ru: "Оригинал",
                            lang
                        ),
                        caption: L10n.t(
                            zhHans: "保持官方原汁原味",
                            zhHant: "保持官方原汁原味",
                            en: "Classic Antigravity look",
                            ru: "Классический вид",
                            lang
                        ),
                        image: appModel.originalAppIcon,
                        selected: appModel.config.runtimeIconStyle == .original
                    ) {
                        appModel.config.runtimeIconStyle = .original
                    }

                    iconPreviewRow(
                        cacheKey: "option-pilot-cat",
                        title: "Pilot",
                        caption: L10n.t(
                            zhHans: "与 Pilot 同款图标",
                            zhHant: "與 Pilot 同款圖示",
                            en: "Same icon as Pilot",
                            ru: "Как значок Pilot",
                            lang
                        ),
                        image: appModel.pilotAppIcon,
                        selected: appModel.config.runtimeIconStyle == .pilotCat
                    ) {
                        appModel.config.runtimeIconStyle = .pilotCat
                    }
                }

                Text(L10n.t(
                    "仅影响代理版 Runtime 副本，伴侣本身保持 Pilot 图标。",
                    "Applies to the proxied runtime copy only; Pilot keeps its own icon.",
                    lang
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func iconPreviewRow(
        cacheKey: String,
        title: String,
        badge: String? = nil,
        caption: String,
        image: NSImage,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(nsImage: PilotIconCache.baked(
                    image,
                    key: cacheKey,
                    side: 32,
                    cornerRadius: 8,
                    shadowBlur: 3,
                    shadowYOffset: 1,
                    shadowAlpha: 0.10
                ))
                .frame(width: 32 + PilotIconCache.margin * 2, height: 32 + PilotIconCache.margin * 2)
                .padding(-PilotIconCache.margin)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .lineLimit(1)

                        if let badge {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.12))
                                )
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13.5))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.35))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var quickActionsStrip: some View {
        PilotCard(padding: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.callout)
                        .foregroundStyle(.purple)
                        .frame(width: 28, height: 28)
                        .background(Color.purple.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("Antigravity 应用内看板", "In-App Dashboard Plugin", lang))
                            .font(.callout.weight(.medium))
                        Text(pluginSummaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .notInstalled = appModel.mcpPluginStatus {
                    Button(L10n.t("一键安装", "Install", lang)) {
                        appModel.installOrUpdateMcpPlugin()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(appModel.isUpdatingMcpPlugin || isBusy)
                } else {
                    Button(L10n.t("管理 ›", "Manage ›", lang)) {
                        onOpenTab(.plugin)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Divider()
                    .frame(height: 24)

                Toggle(L10n.t("显示顶部菜单栏图标", "Show Menu Bar Icon", lang), isOn: $appModel.config.enableMenuBarMonitor)
                    .font(.callout)
                    .disabled(isBusy)
                    .help(L10n.t(
                        "关闭后不显示 macOS 顶部菜单栏小图标；关闭主窗口将直接退出 Pilot。",
                        "Hide the macOS top menu bar icon; closing the main window will quit Pilot.",
                        lang
                    ))
            }
        }
    }

    private var menuBarDisplayCard: some View {
        PilotCard(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(
                        L10n.t(
                            zhHans: "菜单栏显示内容",
                            zhHant: "選單列顯示內容",
                            en: "Menu Bar Display",
                            ru: "Элементы в строке меню",
                            lang
                        ),
                        systemImage: "menubar.rectangle"
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(menuBarPreviewText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    menuBarOptionTile(
                        title: L10n.t(
                            zhHans: "运行状态",
                            zhHant: "執行狀態",
                            en: "Running",
                            ru: "Активность",
                            lang
                        ),
                        sample: "◌2",
                        isOn: appModel.config.showMenuBarRunningStatus
                    ) {
                        appModel.config.showMenuBarRunningStatus.toggle()
                        appModel.config.syncMenuBarMetricsMasterFlag()
                        appModel.savePreferencesOnly()
                    }

                    menuBarOptionTile(
                        title: L10n.t(
                            zhHans: "上下文",
                            zhHant: "上下文",
                            en: "Context",
                            ru: "Контекст",
                            lang
                        ),
                        sample: "18K",
                        isOn: appModel.config.showMenuBarContextUsage
                    ) {
                        appModel.config.showMenuBarContextUsage.toggle()
                        appModel.config.syncMenuBarMetricsMasterFlag()
                        appModel.savePreferencesOnly()
                    }

                    menuBarOptionTile(
                        title: L10n.t(
                            zhHans: "剩余配额",
                            zhHant: "剩餘配額",
                            en: "Quota",
                            ru: "Квота",
                            lang
                        ),
                        sample: "47%",
                        isOn: appModel.config.showMenuBarQuotaPercent
                    ) {
                        appModel.config.showMenuBarQuotaPercent.toggle()
                        appModel.config.syncMenuBarMetricsMasterFlag()
                        appModel.savePreferencesOnly()
                    }
                }
            }
        }
        .disabled(!appModel.config.enableMenuBarMonitor || isBusy)
        .opacity(appModel.config.enableMenuBarMonitor ? 1 : 0.55)
    }

    private var menuBarPreviewText: String {
        guard appModel.config.enableMenuBarMonitor else {
            return L10n.t(
                zhHans: "菜单栏图标已关闭",
                zhHant: "選單列圖示已關閉",
                en: "Menu bar icon hidden",
                ru: "Значок скрыт",
                lang
            )
        }
        var parts: [String] = []
        if appModel.config.showMenuBarContextUsage {
            parts.append("18K")
        }
        if appModel.config.showMenuBarQuotaPercent {
            parts.append("47%")
        }
        let metrics = parts.joined(separator: " · ")
        if appModel.config.showMenuBarRunningStatus {
            return metrics.isEmpty ? "◌2" : "◌2 · \(metrics)"
        }
        if !metrics.isEmpty {
            return metrics
        }
        return L10n.t(
            zhHans: "仅显示图标",
            zhHant: "僅顯示圖示",
            en: "Icon only",
            ru: "Только значок",
            lang
        )
    }

    private func menuBarOptionTile(
        title: String,
        sample: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.45))

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(sample)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(isOn ? Color.secondary : Color.secondary.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pluginSummaryText: String {
        switch appModel.mcpPluginStatus {
        case .notInstalled:
            return L10n.t("未安装（支持边栏全屏 + 对话辅助面板）", "Not installed (sidebar view + aux pane)", lang)
        case .installedCurrent(let ver):
            return L10n.t(
                zhHans: "已安装 v\(ver) · 自动发现生效中",
                zhHant: "已安裝 v\(ver) · 自動探索生效中",
                en: "Installed v\(ver) · Auto-discovery active",
                ru: "Установлен v\(ver) · Автообнаружение активно",
                lang
            )
        case .updateAvailable(_, let bundled):
            return L10n.t(
                zhHans: "有新版本 v\(bundled) 可更新",
                zhHant: "有新版本 v\(bundled) 可更新",
                en: "Update available: v\(bundled)",
                ru: "Доступно обновление: v\(bundled)",
                lang
            )
        case .unavailable:
            return L10n.t("当前构建包未包含 MCP 产物", "MCP assets not bundled in this build", lang)
        }
    }

    private var healthDetailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.t("三阶代理健康诊断", "3-Stage Proxy Diagnostics", lang))
                    .font(.headline)
                Spacer()
                Button(L10n.t("重测", "Re-test", lang)) {
                    appModel.checkProxyHealth()
                }
                .controlSize(.small)
            }

            Divider()

            healthStepRow(
                title: L10n.t(
                    zhHans: "1. 本地 TCP 端口 (\(appModel.config.displayHookHostPort))",
                    zhHant: "1. 本機 TCP 連接埠 (\(appModel.config.displayHookHostPort))",
                    en: "1. Local TCP Port (\(appModel.config.displayHookHostPort))",
                    ru: "1. Локальный TCP порт (\(appModel.config.displayHookHostPort))",
                    lang
                ),
                passed: appModel.healthReport.tcpReachable
            )
            healthStepRow(
                title: L10n.t("2. SOCKS5 协议握手 (05 01 00)", "2. SOCKS5 Handshake (05 01 00)", lang),
                passed: appModel.healthReport.socks5HandshakeOK
            )
            healthStepRow(
                title: L10n.t("3. 代理外网连通 (generate_204)", "3. Internet via Proxy (generate_204)", lang),
                passed: appModel.healthReport.internetReachable
            )
            healthStepRow(
                title: L10n.t(
                    zhHans: "环境变量端口 (\(appModel.config.envProxyURL))",
                    zhHant: "環境變數連接埠 (\(appModel.config.envProxyURL))",
                    en: "ENV Proxy Port (\(appModel.config.envProxyURL))",
                    ru: "Порт ENV прокси (\(appModel.config.envProxyURL))",
                    lang
                ),
                passed: appModel.healthReport.envPortReachable
            )

            Text(appModel.healthReport.detailMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 325)
    }

    private func healthStepRow(title: String, passed: Bool?) -> some View {
        HStack(spacing: 8) {
            if let passed {
                Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(passed ? .green : .red)
            } else {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.callout)
            Spacer()
        }
    }

    private var runningConflictBanner: some View {
        let sep = (lang.resolved == .zhHans || lang.resolved == .zhHant) ? "、" : ", "
        let instanceList = appModel.runningInstances
            .map { "\($0.kind.localizedName(lang)) (PID \($0.id))" }
            .joined(separator: sep)
        return PilotCard(padding: 9, accentTint: .orange) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack(spacing: 6) {
                    Text(L10n.t("检测到 Antigravity 正在运行", "Antigravity Is Running", lang))
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(instanceList)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button(L10n.t("优雅退出并启动", "Quit & Launch", lang)) {
                    appModel.saveAndStart(forceRebuild: false, terminateRunningFirst: true) {
                        onHideToMenuBar()
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isBusy)
            }
        }
    }

    @ViewBuilder
    private var antigravityCheckButton: some View {
        HStack(spacing: 0) {
            switch antigravityUpdateStore.state {
            case .downloading, .verifying, .replacingAndRebuilding:
                EmptyView()
            case .checking:
                ProgressView()
                    .controlSize(.mini)
            default:
                if appModel.runtimeStatusKind != .missingSource {
                    Button {
                        if case .failed = antigravityUpdateStore.state {
                            activeAntigravityPopover = (activeAntigravityPopover == .error ? nil : .error)
                        } else {
                            appModel.refreshRuntimeStatus()
                            if appModel.config.skippedAntigravityVersion != nil {
                                appModel.config.skippedAntigravityVersion = nil
                                appModel.savePreferencesOnly()
                            }
                            antigravityUpdateStore.checkForUpdates(config: appModel.config, userInitiated: true)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            switch antigravityUpdateStore.state {
                            case .upToDate where appModel.runtimeStatusKind == .ready:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(L10n.t("已是最新", "Up to Date", lang))
                                    .foregroundStyle(.green)
                            case .upToDate:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(L10n.t(
                                    zhHans: "原版最新",
                                    zhHant: "原版最新",
                                    en: "Source Latest",
                                    ru: "Оригинал нов.",
                                    lang
                                ))
                                .foregroundStyle(.green)
                            case .available:
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.blue)
                            case .failed:
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                            default:
                                Image(systemName: "arrow.clockwise.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(antigravityCheckButtonHelp)
                }
            }
        }
        .popover(
            isPresented: Binding(
                get: { activeAntigravityPopover != nil },
                set: { presented in
                    if !presented {
                        activeAntigravityPopover = nil
                    }
                }
            ),
            arrowEdge: .bottom
        ) {
            switch activeAntigravityPopover {
            case .error:
                antigravityErrorPopover
            case .upToDateNeedsRebuild:
                antigravityUpToDatePopover
            case nil:
                EmptyView()
            }
        }
    }

    private var antigravityCheckButtonHelp: String {
        switch antigravityUpdateStore.state {
        case .failed:
            return L10n.t("Antigravity 更新失败", "Antigravity Update Failed", lang)
        case .upToDate(let installedVersion, _, _):
            if appModel.runtimeStatusKind == .ready {
                return L10n.t(
                    zhHans: "原版 Antigravity \(installedVersion) 已是官方最新（点击重新检查）",
                    zhHant: "原版 Antigravity \(installedVersion) 已是官方最新（點擊重新檢查）",
                    en: "Original Antigravity \(installedVersion) is up to date (click to re-check)",
                    ru: "Оригинал Antigravity \(installedVersion) актуален (нажмите для повторной проверки)",
                    lang
                )
            }
            return L10n.t(
                zhHans: "原版 Antigravity \(installedVersion) 已是官方最新，但代理副本仍需重建同步（点击重新检查）",
                zhHant: "原版 Antigravity \(installedVersion) 已是官方最新，但代理副本仍需重建同步（點擊重新檢查）",
                en: "Original Antigravity \(installedVersion) is up to date, but the runtime copy needs a rebuild (click to re-check)",
                ru: "Оригинал Antigravity \(installedVersion) актуален, но копию нужно пересобрать (нажмите для проверки)",
                lang
            )
        default:
            return L10n.t("检查 Antigravity 官方更新", "Check for Antigravity updates", lang)
        }
    }

    private var antigravityUpToDatePopover: some View {
        let installedVersion: String = {
            if case .upToDate(let version, _, _) = antigravityUpdateStore.state {
                return version
            }
            return ""
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L10n.t(
                    zhHans: "原版 Antigravity 已是最新",
                    zhHant: "原版 Antigravity 已是最新",
                    en: "Antigravity Source Is Up to Date",
                    ru: "Оригинал Antigravity актуален",
                    lang
                ))
                .font(.callout.weight(.semibold))
            }

            Text(L10n.t(
                zhHans: "原版 Antigravity \(installedVersion) 已是官方最新版本。如需将代理副本同步至最新原版，请点击下方按钮重建副本并启动。",
                zhHant: "原版 Antigravity \(installedVersion) 已是官方最新版本。如需將代理副本同步至最新原版，請點擊下方按鈕重建副本並啟動。",
                en: "Original Antigravity \(installedVersion) is already the latest official release. Click below to rebuild and sync the runtime copy.",
                ru: "Оригинальный Antigravity \(installedVersion) уже обновлён до последней версии. Нажмите ниже, чтобы пересобрать и синхронизировать копию.",
                lang
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.t("关闭", "Dismiss", lang)) {
                    activeAntigravityPopover = nil
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(primaryButtonTitle) {
                    activeAntigravityPopover = nil
                    appModel.saveAndStart(
                        forceRebuild: false,
                        terminateRunningFirst: !appModel.runningInstances.isEmpty
                    ) {
                        onHideToMenuBar()
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .padding(12)
        .frame(width: 285)
    }

    private var antigravityErrorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(L10n.t("Antigravity 更新失败", "Antigravity Update Failed", lang))
                    .font(.callout.weight(.semibold))
            }

            if case .failed(let message, _) = antigravityUpdateStore.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.t("关闭", "Dismiss", lang)) {
                    activeAntigravityPopover = nil
                    antigravityUpdateStore.dismissFailure()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(L10n.t("重试", "Retry", lang)) {
                    activeAntigravityPopover = nil
                    antigravityUpdateStore.checkForUpdates(config: appModel.config, userInitiated: true)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var shouldShowAntigravityUpdateBanner: Bool {
        switch antigravityUpdateStore.state {
        case .available(_, let manifest, _, _):
            return manifest.version != appModel.config.skippedAntigravityVersion
        case .downloading, .verifying, .replacingAndRebuilding, .readyForManualInstall:
            return true
        case .idle, .checking, .upToDate, .failed:
            return false
        }
    }

    @ViewBuilder
    private var antigravityUpdateBanner: some View {
        switch antigravityUpdateStore.state {
        case .available(let installedVersion, let manifest, let route, _):
            PilotCard(padding: 9, accentTint: .blue) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L10n.t(
                                zhHans: "发现 Antigravity 新版 \(installedVersion) → \(manifest.version)",
                                zhHant: "發現 Antigravity 新版 \(installedVersion) → \(manifest.version)",
                                en: "Antigravity Update \(installedVersion) → \(manifest.version)",
                                ru: "Доступен Antigravity \(installedVersion) → \(manifest.version)",
                                lang
                            ))
                            .font(.callout.weight(.semibold))
                            if let size = manifest.size, size > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(route.localizedLabel(lang))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button(L10n.t("忽略", "Ignore", lang)) {
                        appModel.config.skippedAntigravityVersion = manifest.version
                        appModel.savePreferencesOnly()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)

                    Button(L10n.t("一键更新原版并重建", "Update & Rebuild", lang)) {
                        antigravityUpdateStore.startUpdateAndRebuild(appModel: appModel) {
                            onHideToMenuBar()
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }
            }

        case .downloading(let manifest, let downloaded, let total, let route):
            let fraction = total > 0 ? min(max(Double(downloaded) / Double(total), 0), 1) : 0
            let percent = total > 0 ? Int((fraction * 100).rounded()) : 0
            PilotCard(padding: 9, accentTint: .blue) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.t(
                            zhHans: "正在下载 Antigravity \(manifest.version)...",
                            zhHant: "正在下載 Antigravity \(manifest.version)...",
                            en: "Downloading Antigravity \(manifest.version)...",
                            ru: "Загрузка Antigravity \(manifest.version)...",
                            lang
                        ))
                        .font(.callout.weight(.semibold))
                        Spacer()
                        let downloadedStr = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
                        let totalStr = total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "…"
                        Text("\(downloadedStr) / \(totalStr) (\(percent)%) · \(route.localizedLabel(lang))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button(L10n.t("取消", "Cancel", lang)) {
                            antigravityUpdateStore.cancelDownload()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    PilotLinearBar(fraction: fraction, tint: .blue, height: 6)
                }
            }

        case .verifying(let manifest, let stage), .replacingAndRebuilding(let manifest, let stage):
            PilotCard(padding: 9, accentTint: .blue) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t(
                            zhHans: "正在更新 Antigravity \(manifest.version)",
                            zhHant: "正在更新 Antigravity \(manifest.version)",
                            en: "Updating Antigravity \(manifest.version)",
                            ru: "Обновление Antigravity \(manifest.version)",
                            lang
                        ))
                        .font(.callout.weight(.semibold))
                        Text(stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

        case .readyForManualInstall(_, _, let reason):
            PilotCard(padding: 9, accentTint: .orange) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("需手动更新 Antigravity", "Manual Antigravity Update", lang))
                            .font(.callout.weight(.semibold))
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(L10n.t("在 Finder 中显示", "Reveal in Finder", lang)) {
                        antigravityUpdateStore.revealManualInstallerInFinder()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }

        case .idle, .checking, .upToDate, .failed:
            EmptyView()
        }
    }

    private func messageBanner(_ message: String, isError: Bool) -> some View {
        let color: Color = isError ? .red : .green
        return PilotCard(padding: 9, accentTint: color) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isError ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(color)
                    .padding(.top, 1)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hotUpdatePillColor: Color {
        switch appModel.hotUpdateStatus {
        case .hotUpdateReady:
            return .green
        case .missingSourceApp, .runtimeNotBuilt:
            return .secondary
        case .runtimeIncomplete, .proxyBinaryUpdated, .legacyUpdaterPresent,
             .sourceVersionChanged, .iconStyleChanged, .pilotIconUpdated, .signatureInvalid:
            return .orange
        }
    }

    private var heroAccentTint: Color {
        switch appModel.healthReport.level {
        case .healthy: return .green
        case .degraded: return .orange
        case .failed: return .red
        case .checking: return .blue
        }
    }

    private var runtimeSummaryColor: Color {
        switch appModel.runtimeStatusKind {
        case .ready: return .green
        case .updateNeeded: return .orange
        case .notBuilt: return .secondary
        case .missingSource: return .red
        }
    }

    private var primaryButtonTitle: String {
        if appModel.isWorking { return appModel.status }
        if !appModel.runningInstances.isEmpty {
            return appModel.canHotUpdate
                ? L10n.t("退出旧进程并热重启", "Quit & Hot Restart", lang)
                : L10n.t("退出旧进程并重建", "Quit & Rebuild", lang)
        }
        return appModel.canHotUpdate
            ? L10n.t("保存并极速启动", "Save & Quick Launch", lang)
            : L10n.t("重建副本并启动", "Build & Launch", lang)
    }
}
