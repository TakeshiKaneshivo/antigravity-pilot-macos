import AppKit
import SwiftUI

struct ProxyConfigView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var appModel: AppModel
    var onHideToMenuBar: () -> Void
    var onOpenTab: (MainTab) -> Void

    @State private var showHealthPopover = false

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
            VStack(alignment: .leading, spacing: 9) {
                if !appModel.runningInstances.isEmpty {
                    runningConflictBanner
                }

                heroLaunchCard

                EqualHeightTwoColumnLayout(spacing: 12, trailingWidth: 230) {
                    proxySettingsCard
                        .disabled(appModel.isWorking)

                    iconStyleCard
                        .disabled(appModel.isWorking)
                }

                quickActionsStrip

                if let error = appModel.errorMessage {
                    messageBanner(error, isError: true)
                } else if let success = appModel.bannerSuccessMessage {
                    messageBanner(success, isError: false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
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
        .onChange(of: appModel.config.useOriginalIcon) { _ in
            appModel.refreshRuntimeStatus()
        }
        .onChange(of: appModel.config.enableMenuBarMonitor) { _ in
            appModel.savePreferencesOnly()
        }
        .onChange(of: appModel.config.showMenuBarMetrics) { _ in
            appModel.savePreferencesOnly()
        }
    }

    private var heroLaunchCard: some View {
        PilotCard(padding: 12, accentTint: heroAccentTint) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    Image(nsImage: PilotIconCache.baked(
                        appModel.previewIcon,
                        key: appModel.config.useOriginalIcon ? "preview-original" : "preview-pilot",
                        side: 44,
                        cornerRadius: 10,
                        shadowBlur: 6,
                        shadowYOffset: 2,
                        shadowAlpha: 0.14
                    ))
                    .frame(width: 44 + PilotIconCache.margin * 2, height: 44 + PilotIconCache.margin * 2)
                    .padding(-PilotIconCache.margin)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(L10n.t("Antigravity Pilot 代理副本", "Antigravity Pilot Runtime", lang))
                                .font(.headline.weight(.semibold))
                            PilotStatusPill(
                                text: appModel.canHotUpdate
                                    ? L10n.t("0.1s 免重建热更新", "0.1s Hot Update", lang)
                                    : L10n.t("需重建/重签副本", "Rebuild Required", lang),
                                color: appModel.canHotUpdate ? .green : .secondary,
                                showDot: false,
                                systemImage: appModel.canHotUpdate ? "bolt.fill" : "shippingbox"
                            )
                        }
                        Text(appModel.runtimeSummary)
                            .font(.caption)
                            .foregroundStyle(runtimeSummaryColor)
                            .lineLimit(1)
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
                    .disabled(appModel.isWorking)
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
                HStack {
                    Label(L10n.t("核心代理配置", "Core Proxy Settings", lang), systemImage: "network")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(appModel.config.hookProxyURL)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
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
            }
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

    private var iconStyleCard: some View {
        PilotCard(padding: 12, fillHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.t("应用图标样式", "App Icon Style", lang), systemImage: "app.badge")
                    .font(.subheadline.weight(.semibold))

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        iconPreviewOption(
                            cacheKey: "option-pilot",
                            title: L10n.t("Pilot 标识", "Pilot Icon", lang),
                            caption: L10n.t("Dock 易区分", "Distinct", lang),
                            image: appModel.pilotAppIcon,
                            selected: !appModel.config.useOriginalIcon
                        ) {
                            appModel.config.useOriginalIcon = false
                        }

                        iconPreviewOption(
                            cacheKey: "option-original",
                            title: L10n.t("原版图标", "Original", lang),
                            caption: L10n.t("原汁原味", "Classic", lang),
                            image: appModel.originalAppIcon,
                            selected: appModel.config.useOriginalIcon
                        ) {
                            appModel.config.useOriginalIcon = true
                        }
                    }

                    Spacer(minLength: 0)
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

    private func iconPreviewOption(
        cacheKey: String,
        title: String,
        caption: String,
        image: NSImage,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: PilotIconCache.baked(
                        image,
                        key: cacheKey,
                        side: 42,
                        cornerRadius: 10,
                        shadowBlur: 4.5,
                        shadowYOffset: 1,
                        shadowAlpha: 0.12
                    ))
                    .frame(width: 42 + PilotIconCache.margin * 2, height: 42 + PilotIconCache.margin * 2)
                    .padding(-PilotIconCache.margin)
                    .padding(4)

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(Color(NSColor.windowBackgroundColor)).padding(2))
                    }
                }

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)

                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.8 : 1)
            )
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
                    .disabled(appModel.isUpdatingMcpPlugin || appModel.isWorking)
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
                    .disabled(appModel.isWorking)
                    .help(L10n.t(
                        "关闭后不显示 macOS 顶部菜单栏小图标；关闭主窗口将直接退出 Pilot。",
                        "Hide the macOS top menu bar icon; closing the main window will quit Pilot.",
                        lang
                    ))
            }
        }
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
                .disabled(appModel.isWorking)
            }
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
