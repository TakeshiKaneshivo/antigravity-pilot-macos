import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var monitorStore: MonitorStore
    var onOpenMainWindow: () -> Void
    var onClosePopover: () -> Void
    var onQuit: () -> Void

    private var lang: AppLanguage {
        appModel.config.appLanguage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            PilotRecessedBox(padding: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .font(.caption)
                        .foregroundStyle(healthColor)
                    Text("\(L10n.t("代理", "Proxy", lang)) \(appModel.config.displayHookHostPort)")
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    PilotStatusPill(text: appModel.healthReport.summaryTitle, color: healthColor)
                }
            }

            liveContextBox
            quotaBox
            todayUsageBox
            actionsRow
        }
        .padding(14)
        .frame(width: 344)
        .environment(\.appLanguage, lang)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(nsImage: appModel.pilotAppIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Antigravity Pilot")
                    .font(.callout.weight(.semibold))
                Text(
                    monitorStore.liveHub != nil
                        ? {
                            let ver = (monitorStore.liveHub?.lsVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            let suffix = ver.isEmpty ? "" : " v\(ver)"
                            return L10n.t(
                                zhHans: "已连接 LS\(suffix)",
                                zhHant: "已連線 LS\(suffix)",
                                en: "Connected LS\(suffix)",
                                ru: "Подключён LS\(suffix)",
                                lang
                            )
                        }()
                        : L10n.t("等待 Antigravity 启动", "Waiting for Antigravity", lang)
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appModel.checkProxyHealth()
                monitorStore.refreshAll(forceHistory: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.t("刷新状态", "Refresh", lang))
        }
    }

    private var healthColor: Color {
        switch appModel.healthReport.level {
        case .checking: return .secondary
        case .healthy: return .green
        case .degraded: return .orange
        case .failed: return .red
        }
    }

    private var liveContextBox: some View {
        PilotRecessedBox(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.t("当前会话上下文", "Active Context", lang))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let ctx = monitorStore.activeContext {
                        Text(ctx.modelDisplayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let ctx = monitorStore.activeContext {
                    let tint: Color = ctx.usageFraction >= 0.85 ? .red : (ctx.usageFraction >= 0.65 ? .orange : .accentColor)
                    PilotLinearBar(fraction: ctx.usageFraction, tint: tint, height: 6)

                    HStack {
                        Text("\(TokenFormatting.compactTokens(ctx.activeContextTokens)) / \(TokenFormatting.compactTokens(ctx.contextLimitTokens))")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                        Spacer()
                        if let tps = ctx.tokensPerSecond {
                            Text(String(format: "%.1f tok/s", tps))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(L10n.t("暂无活跃会话上下文", "No active session context", lang))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var quotaBox: some View {
        PilotRecessedBox(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.t("主配额池余量", "Primary Quota Pool", lang))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let quota = monitorStore.primaryQuotaPool {
                        Text(quota.resetCountdownText(lang))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let quota = monitorStore.primaryQuotaPool {
                    let tint: Color = quota.remainingPercent <= 15 ? .red : (quota.remainingPercent <= 35 ? .orange : .green)
                    HStack(spacing: 8) {
                        PilotLinearBar(fraction: quota.remainingFraction, tint: tint, height: 6)
                        Text("\(quota.remainingPercent)%")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                    }
                } else {
                    Text(L10n.t("未连接到模型配额服务", "Not connected to quota service", lang))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var todayUsageBox: some View {
        let today = monitorStore.usageHistory.totalsByPeriod[.today]
        return PilotRecessedBox(padding: 9) {
            HStack {
                Text(L10n.t("今日消耗", "Today's Usage", lang))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(TokenFormatting.compactTokens(today?.totalTokens ?? 0)) · \(TokenFormatting.usd(today?.estimatedCostUSD ?? 0))")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            Button(L10n.t("打开主窗口", "Open Window", lang)) {
                onClosePopover()
                onOpenMainWindow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(L10n.t("启动 Pilot", "Launch Pilot", lang)) {
                onClosePopover()
                appModel.launchExistingRuntimeOnly()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button(L10n.t("退出", "Quit", lang)) {
                onQuit()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}
