import AppKit
import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var appModel: AppModel
    var onHideToMenuBar: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                languageCard
                    .disabled(appModel.isWorking)

                chartPaletteCard
                    .disabled(appModel.isWorking)

                noProxyCard
                    .disabled(appModel.isWorking)

                behaviorCard
                    .disabled(appModel.isWorking)

                maintenanceCard
                    .disabled(appModel.isWorking)

                if let error = appModel.errorMessage {
                    messageBanner(error, isError: true)
                } else if let success = appModel.bannerSuccessMessage {
                    messageBanner(success, isError: false)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Label(L10n.t("界面语言", "Language", lang), systemImage: "globe")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Picker("", selection: $appModel.config.appLanguage) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName(in: lang)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 185)
                }

                if appModel.config.appLanguage == .system {
                    Text(L10n.t(
                        zhHans: "当前跟随系统语言：简体中文（不支持的系统语言默认显示 English）",
                        zhHant: "目前跟隨系統語言：繁體中文（不支援的系統語言預設顯示 English）",
                        en: "Following system language: English (unsupported languages default to English)",
                        ru: "Язык системы: Русский (неподдерживаемые языки по умолчанию — English)",
                        lang
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
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

    private var noProxyCard: some View {
        PilotCard(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L10n.t("NO_PROXY 绕过规则", "NO_PROXY Bypass Rules", lang), systemImage: "arrow.triangle.branch")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(L10n.t("恢复默认", "Reset Defaults", lang)) {
                        appModel.config.noProxy = ProxyConfig.defaultNoProxy
                        appModel.saveNoProxyNow()
                    }
                    .controlSize(.small)
                }

                Text(L10n.t(
                    "支持局域网 CIDR（如 192.168.0.0/16）与域名后缀（如 *.local），同时作用于 dylib hook、环境变量与 Chromium 主进程。",
                    "Supports LAN CIDRs (e.g. 192.168.0.0/16) and domain suffixes (e.g. *.local) across dylib hook, env vars, and Chromium.",
                    lang
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)

                TextField("localhost,127.0.0.1,192.168.0.0/16,*.local", text: $appModel.config.noProxy, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...3)
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private var behaviorCard: some View {
        PilotCard(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.t("菜单栏与开机自启", "Menu Bar & Login Item", lang), systemImage: "menubar.rectangle")
                    .font(.subheadline.weight(.semibold))

                Divider()

                Toggle(
                    L10n.t(
                        "显示顶部菜单栏图标（关闭窗口后缩入菜单栏常驻监控）",
                        "Show top menu bar icon (minimize to menu bar when window closes)",
                        lang
                    ),
                    isOn: $appModel.config.enableMenuBarMonitor
                )
                .font(.callout)

                if appModel.config.enableMenuBarMonitor {
                    Toggle(
                        L10n.t(
                            "菜单栏显示实时上下文与配额指标（如 188K · 89%）",
                            "Show live context & quota metrics in menu bar (e.g. 188K · 89%)",
                            lang
                        ),
                        isOn: Binding(
                            get: { appModel.config.hasAnyMenuBarContent },
                            set: { enabled in
                                appModel.config.setMenuBarMetricsMaster(enabled)
                                appModel.savePreferencesOnly()
                            }
                        )
                    )
                    .font(.callout)
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

    private var maintenanceCard: some View {
        PilotCard(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.t("通道摘要与副本维护", "Channel Summary & Maintenance", lang), systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))

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

    private func messageBanner(_ message: String, isError: Bool) -> some View {
        let color: Color = isError ? .red : .green
        return PilotCard(padding: 11, accentTint: color) {
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
}
