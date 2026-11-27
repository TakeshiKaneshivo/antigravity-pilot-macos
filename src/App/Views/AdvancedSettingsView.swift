import AppKit
import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var appModel: AppModel
    var onHideToMenuBar: () -> Void

    @State private var isNoProxyExpanded = false
    @State private var isMaintenanceExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                languageCard
                    .disabled(appModel.isAnyOperationBusy)

                chartPaletteCard
                    .disabled(appModel.isAnyOperationBusy)

                behaviorCard
                    .disabled(appModel.isAnyOperationBusy)

                noProxyCard
                    .disabled(appModel.isAnyOperationBusy)

                maintenanceCard
                    .disabled(appModel.isAnyOperationBusy)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .onChange(of: appModel.config.appLanguage) { _ in
            appModel.applyLanguageChange()
        }
        .onChange(of: appModel.config.chartPalette) { _ in
            appModel.savePreferencesOnly()
        }
        .onChange(of: appModel.config.noProxy) { _ in
            appModel.scheduleSaveNoProxy()
        }
        .onChange(of: appModel.config.enableMenuBarMonitor) { _ in
            appModel.savePreferencesOnly()
        }
    }

    private var languageCard: some View {
        PilotCard(padding: 10) {
            HStack(spacing: 12) {
                Label(L10n.t("界面语言", "Language", lang), systemImage: "globe")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if appModel.config.appLanguage == .system {
                    Text(L10n.t(
                        zhHans: "跟随系统",
                        zhHant: "跟隨系統",
                        en: "Auto",
                        ru: "Авто",
                        lang
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(L10n.t(
                        zhHans: "当前跟随系统语言：简体中文（不支持的系统语言默认显示 English）",
                        zhHant: "目前跟隨系統語言：繁體中文（不支援的系統語言預設顯示 English）",
                        en: "Following system language: English (unsupported languages default to English)",
                        ru: "Язык системы: Русский (неподдерживаемые языки по умолчанию — English)",
                        lang
                    ))
                }

                Picker("", selection: $appModel.config.appLanguage) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName(in: lang)).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 185)
            }
        }
    }

    private var chartPaletteCard: some View {
        let swatches = PilotMorandiPalette.previewSwatches(preset: appModel.config.chartPalette, colorScheme: colorScheme)
        return PilotCard(padding: 10) {
            HStack(spacing: 10) {
                Label(
                    L10n.t(
                        zhHans: "图表配色",
                        zhHant: "圖表配色",
                        en: "Chart Palette",
                        ru: "Палитра графиков",
                        lang
                    ),
                    systemImage: "paintpalette"
                )
                .font(.subheadline.weight(.semibold))

                Spacer()

                HStack(spacing: 4) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                        Circle()
                            .fill(swatch)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.12), lineWidth: 0.5)
                            )
                    }
                }
                .padding(.trailing, 2)

                Picker("", selection: $appModel.config.chartPalette) {
                    ForEach(ChartPalettePreset.allCases) { option in
                        Text(option.displayName(in: lang)).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 185)
            }
            .help(L10n.t(
                zhHans: "应用于热力图、趋势图、占比图、KPI 图标与上下文构成，并同步至应用内插件看板",
                zhHant: "套用於熱力圖、趨勢圖、佔比圖、KPI 圖示與上下文構成，並同步至應用內外掛看板",
                en: "Applies to heatmap, trend, breakdown charts, KPI icons & context breakdown, synced with the in-app plugin dashboard",
                ru: "Применяется к графикам, KPI и составу контекста, синхронизируется с панелью плагина",
                lang
            ))
        }
    }

    private var behaviorCard: some View {
        PilotCard(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.t("菜单栏与开机自启", "Menu Bar & Login Item", lang), systemImage: "menubar.rectangle")
                    .font(.subheadline.weight(.semibold))

                Divider()

                HStack(spacing: 10) {
                    Toggle(
                        L10n.t("显示顶部菜单栏图标", "Show Menu Bar Icon", lang),
                        isOn: $appModel.config.enableMenuBarMonitor
                    )
                    .font(.callout)
                    .help(L10n.t(
                        zhHans: "关闭后不显示 macOS 顶部菜单栏小图标；关闭主窗口将直接退出 Pilot。",
                        zhHant: "關閉後不顯示 macOS 頂部選單列小圖示；關閉主視窗將直接結束 Pilot。",
                        en: "Hide the macOS top menu bar icon; closing the main window will quit Pilot.",
                        ru: "Скрыть значок в строке меню macOS; закрытие главного окна завершит Pilot.",
                        lang
                    ))

                    Spacer(minLength: 8)

                    Text(L10n.t(
                        zhHans: "关闭窗口后常驻菜单栏",
                        zhHant: "關閉視窗後常駐選單列",
                        en: "Minimize to menu bar on close",
                        ru: "Сворачивать в меню при закрытии",
                        lang
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                if appModel.config.enableMenuBarMonitor {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Text(L10n.t(
                                zhHans: "菜单栏显示内容",
                                zhHant: "選單列顯示內容",
                                en: "Menu Bar Display",
                                ru: "Строка меню",
                                lang
                            ))
                            .font(.callout)
                            .lineLimit(1)

                            Text(menuBarPreviewText)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.primary.opacity(0.05))
                                )
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        HStack(spacing: 6) {
                            menuBarCheckboxChip(
                                title: L10n.t(
                                    zhHans: "运行状态",
                                    zhHant: "執行狀態",
                                    en: "Running",
                                    ru: "Статус",
                                    lang
                                ),
                                isOn: appModel.config.showMenuBarRunningStatus
                            ) {
                                appModel.config.showMenuBarRunningStatus.toggle()
                                appModel.config.syncMenuBarMetricsMasterFlag()
                                appModel.savePreferencesOnly()
                            }

                            menuBarCheckboxChip(
                                title: L10n.t(
                                    zhHans: "上下文",
                                    zhHant: "上下文",
                                    en: "Context",
                                    ru: "Контекст",
                                    lang
                                ),
                                isOn: appModel.config.showMenuBarContextUsage
                            ) {
                                appModel.config.showMenuBarContextUsage.toggle()
                                appModel.config.syncMenuBarMetricsMasterFlag()
                                appModel.savePreferencesOnly()
                            }

                            menuBarCheckboxChip(
                                title: L10n.t(
                                    zhHans: "剩余配额",
                                    zhHant: "剩餘配額",
                                    en: "Quota",
                                    ru: "Квота",
                                    lang
                                ),
                                isOn: appModel.config.showMenuBarQuotaPercent
                            ) {
                                appModel.config.showMenuBarQuotaPercent.toggle()
                                appModel.config.syncMenuBarMetricsMasterFlag()
                                appModel.savePreferencesOnly()
                            }
                        }
                    }
                    .padding(.leading, 18)
                }

                Divider()

                HStack {
                    Toggle(
                        L10n.t("开机登录时自动启动 Antigravity Pilot", "Launch Antigravity Pilot at login", lang),
                        isOn: Binding(
                            get: { appModel.loginItemEnabled },
                            set: { appModel.setLoginItem($0) }
                        )
                    )
                    .font(.callout)
                    Spacer()
                    PilotStatusPill(
                        text: appModel.loginItemStatus,
                        color: appModel.loginItemEnabled ? .green : .secondary,
                        showDot: false
                    )
                }
            }
        }
    }

    private var menuBarPreviewText: String {
        var parts: [String] = []
        if appModel.config.showMenuBarContextUsage {
            parts.append("148K")
        }
        if appModel.config.showMenuBarQuotaPercent {
            parts.append("5h39%")
        }
        let metrics = parts.joined(separator: " ")
        if appModel.config.showMenuBarRunningStatus {
            return metrics.isEmpty ? "◌2" : "◌2 \(metrics)"
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

    private func menuBarCheckboxChip(
        title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.45))

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.38) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var noProxyRuleCount: Int {
        appModel.config.effectiveNoProxy
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private var noProxyCard: some View {
        PilotCard(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isNoProxyExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Label(L10n.t("NO_PROXY 绕过规则", "NO_PROXY Bypass Rules", lang), systemImage: "arrow.triangle.branch")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 8)

                        Text(L10n.t(
                            zhHans: "\(noProxyRuleCount) 条规则",
                            zhHant: "\(noProxyRuleCount) 條規則",
                            en: "\(noProxyRuleCount) rules",
                            ru: "\(noProxyRuleCount) правил",
                            lang
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isNoProxyExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isNoProxyExpanded {
                    Divider()

                    HStack(alignment: .center, spacing: 8) {
                        Text(L10n.t(
                            "支持局域网 CIDR（如 192.168.0.0/16）与域名后缀（如 *.local），同时作用于 dylib hook、环境变量与 Chromium 主进程。",
                            "Supports LAN CIDRs (e.g. 192.168.0.0/16) and domain suffixes (e.g. *.local) across dylib hook, env vars, and Chromium.",
                            lang
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        Spacer(minLength: 8)

                        Button(L10n.t("恢复默认", "Reset Defaults", lang)) {
                            appModel.config.noProxy = ProxyConfig.defaultNoProxy
                            appModel.saveNoProxyNow()
                        }
                        .controlSize(.small)
                    }

                    TextField("localhost,127.0.0.1,192.168.0.0/16,*.local", text: $appModel.config.noProxy, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    private var maintenanceCard: some View {
        PilotCard(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isMaintenanceExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Label(L10n.t("通道摘要与副本维护", "Channel Summary & Maintenance", lang), systemImage: "wrench.and.screwdriver")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 8)

                        Text("socks5 :\(appModel.config.hookPort)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isMaintenanceExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isMaintenanceExpanded {
                    Divider()

                    PilotRecessedBox(padding: 7) {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("dylib Hook: \(appModel.config.hookProxyURL)")
                                .font(.system(.caption, design: .monospaced))
                            Text("Env / Chromium: \(appModel.config.envProxyURL)")
                                .font(.system(.caption, design: .monospaced))
                            Text("\(L10n.t("配置目录", "Config Dir", lang)): \(appModel.support.root.path)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    HStack {
                        Button(L10n.t("打开配置目录", "Open Config Folder", lang)) {
                            try? appModel.support.ensureRoot()
                            NSWorkspace.shared.open(appModel.support.root)
                        }
                        .controlSize(.small)

                        Spacer()

                        Button(L10n.t("强制完整重建副本", "Force Full Rebuild", lang)) {
                            appModel.saveAndStart(
                                forceRebuild: true,
                                terminateRunningFirst: !appModel.runningInstances.isEmpty
                            ) {
                                onHideToMenuBar()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
