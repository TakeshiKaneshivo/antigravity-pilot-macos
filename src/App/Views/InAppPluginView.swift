import SwiftUI

struct InAppPluginView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                heroCard

                HStack(alignment: .top, spacing: 12) {
                    entrypointCard(
                        title: L10n.t("左侧边栏 ·「Pilot 用量与账单」", "Left Sidebar · Pilot Usage & Billing", lang),
                        badge: L10n.t("global 全屏视图", "global full-screen view", lang),
                        icon: "sidebar.left",
                        tint: .indigo,
                        points: [
                            L10n.t("近一年（52 周）Token 活跃热力图（支持单日明细点击）", "1-year (52-week) token heatmap with clickable daily details", lang),
                            L10n.t("近 14 日 Token 趋势柱状图与模型占比环形图", "14-day token bar chart & model breakdown donut", lang),
                            L10n.t("今日 / 7 天 / 30 天 / 全部周期估算 API 账单", "Estimated API cost across Today / 7d / 30d / All", lang)
                        ]
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    entrypointCard(
                        title: L10n.t("对话右上角 + ·「Pilot 实时监控」", "Chat Top-Right + · Pilot Live Monitor", lang),
                        badge: L10n.t("aux_pane 辅助面板", "aux_pane side panel", lang),
                        icon: "sidebar.right",
                        tint: .teal,
                        points: [
                            L10n.t("本地代理只读参数与三阶健康实时探测（TCP / SOCKS5 / 204）", "Read-only proxy params & live 3-stage probe (TCP / SOCKS5 / 204)", lang),
                            L10n.t("当前会话上下文占用环、缓存命中率、TTFT 与生成速度", "Live context gauge, cache hit rate, TTFT & tok/s", lang),
                            L10n.t("模型共享配额池余量与重置倒计时（可见时 5 秒自动刷新）", "Shared quota pool bars & reset countdown (5s auto-refresh)", lang)
                        ]
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                techInfoCard
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
    }

    private var heroCard: some View {
        PilotCard(padding: 15, accentTint: .purple) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.purple)
                        .frame(width: 44, height: 44)
                        .background(Color.purple.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(L10n.t("Antigravity 应用内看板插件", "Antigravity In-App Dashboard Plugin", lang))
                                .font(.headline.weight(.semibold))
                            statusPill
                        }
                        Text(L10n.t(
                            "基于官方 MCP Apps (SEP-1865) 协议与原生 Swift 后端构建，零 JS 注入，自动跟随亮暗主题。",
                            "Built on official MCP Apps (SEP-1865) and native Swift backend with zero JS injection and automatic light/dark theme.",
                            lang
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                HStack(spacing: 12) {
                    Toggle(
                        L10n.t("在 Antigravity 应用内显示监控与账单", "Show Monitor & Billing inside Antigravity", lang),
                        isOn: Binding(
                            get: { appModel.mcpPluginStatus.isInstalled },
                            set: { enable in
                                if enable {
                                    appModel.installOrUpdateMcpPlugin()
                                } else {
                                    appModel.uninstallMcpPlugin()
                                }
                            }
                        )
                    )
                    .font(.callout.weight(.medium))
                    .disabled(isToggleDisabled)

                    Spacer()

                    if appModel.isUpdatingMcpPlugin {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        actionButtons
                    }
                }
            }
        }
    }

    private var isToggleDisabled: Bool {
        if appModel.isWorking || appModel.isUpdatingMcpPlugin { return true }
        if case .unavailable = appModel.mcpPluginStatus { return true }
        return false
    }

    private func entrypointCard(
        title: String,
        badge: String,
        icon: String,
        tint: Color,
        points: [String]
    ) -> some View {
        PilotCard(padding: 14, fillHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(badge)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(tint)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(tint.opacity(0.8))
                                .padding(.top, 2)
                            Text(point)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var techInfoCard: some View {
        PilotCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L10n.t("插件部署与运行说明", "Deployment & Runtime Notes", lang), systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    PilotStatusPill(
                        text: L10n.t("原版 & Pilot 副本通用", "Original & Pilot Compatible", lang),
                        color: .green,
                        showDot: false,
                        systemImage: "checkmark.seal.fill"
                    )
                }

                PilotRecessedBox(padding: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(L10n.t("安装目录", "Install Dir", lang)): \(appModel.support.mcpPluginDirectory.path)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(L10n.t(
                            "• 安装或更新后会自动通知运行中的 Antigravity Language Server 重载插件，无需重启应用；刷新数据时通过 App-only 工具执行，不消耗任何模型 Token。",
                            "• Automatically notifies running Antigravity Language Server to reload after install/update with zero restart; refreshes run via app-only tools and consume 0 tokens.",
                            lang
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        Text(L10n.t(
                            "• 随插件同步部署原生生命周期 hooks.json（任务完成与提问秒级提醒，绝不修改命令执行权限门禁），卸载时一并移除。",
                            "• Deploys native lifecycle hooks.json alongside the plugin for instant task & prompt alerts (never overrides command approvals), cleanly removed on uninstall.",
                            lang
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        Text(L10n.t(
                            "• 为防止在 Antigravity 内部自我重启造成连接中断，应用内面板保持代理配置只读 + 实时三阶探测；修改端口或绕过规则请回到「代理概览 / 高级设置」。",
                            "• To avoid self-restart disconnects inside Antigravity, the in-app panel keeps proxy config read-only + live probing; edit ports or bypass rules in Proxy Overview / Settings.",
                            lang
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch appModel.mcpPluginStatus {
        case .notInstalled:
            PilotStatusPill(text: L10n.t("未安装", "Not Installed", lang), color: .secondary, showDot: false)
        case .installedCurrent(let ver):
            PilotStatusPill(
                text: L10n.t(
                    zhHans: "已安装 v\(ver)",
                    zhHant: "已安裝 v\(ver)",
                    en: "Installed v\(ver)",
                    ru: "Установлен v\(ver)",
                    lang
                ),
                color: .green
            )
        case .updateAvailable(_, let bundled):
            PilotStatusPill(
                text: L10n.t(
                    zhHans: "有更新 v\(bundled)",
                    zhHant: "有更新 v\(bundled)",
                    en: "Update v\(bundled)",
                    ru: "Обновление v\(bundled)",
                    lang
                ),
                color: .orange
            )
        case .unavailable(let reason):
            PilotStatusPill(text: L10n.t("不可用", "Unavailable", lang), color: .red)
                .help(reason)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch appModel.mcpPluginStatus {
        case .notInstalled:
            Button(L10n.t("安装到 Antigravity", "Install to Antigravity", lang)) {
                appModel.installOrUpdateMcpPlugin()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .updateAvailable:
            HStack(spacing: 6) {
                Button(L10n.t("更新插件", "Update", lang)) {
                    appModel.installOrUpdateMcpPlugin()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(L10n.t("卸载", "Uninstall", lang)) {
                    appModel.uninstallMcpPlugin()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .installedCurrent:
            HStack(spacing: 6) {
                Button(L10n.t("重新同步", "Re-sync", lang)) {
                    appModel.installOrUpdateMcpPlugin()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(L10n.t("卸载", "Uninstall", lang)) {
                    appModel.uninstallMcpPlugin()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .unavailable:
            EmptyView()
        }
    }
}
