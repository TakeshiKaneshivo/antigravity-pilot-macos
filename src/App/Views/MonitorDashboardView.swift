import SwiftUI

struct MonitorDashboardView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var appModel: AppModel
    @ObservedObject var monitorStore: MonitorStore

    @State private var expandedPoolIds: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerStrip

                if let err = monitorStore.lastLiveError {
                    PilotCard(padding: 11, accentTint: .orange) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(L10n.t(
                                zhHans: "本地监控刷新异常：\(err)",
                                zhHant: "本機監控重新整理異常：\(err)",
                                en: "Local monitor refresh error: \(err)",
                                ru: "Ошибка обновления монитора: \(err)",
                                lang
                            ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if monitorStore.liveHub == nil {
                    emptyRunningState
                } else {
                    contextCard
                    quotaSection
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
    }

    private var headerStrip: some View {
        HStack(spacing: 10) {
            if let hub = monitorStore.liveHub {
                let ver = hub.lsVersion ?? L10n.t("未知", "Unknown", lang)
                PilotStatusPill(
                    text: L10n.t(
                        zhHans: "已连接 LS v\(ver) · PID \(hub.pid)",
                        zhHant: "已連線 LS v\(ver) · PID \(hub.pid)",
                        en: "Connected LS v\(ver) · PID \(hub.pid)",
                        ru: "Подключён LS v\(ver) · PID \(hub.pid)",
                        lang
                    ),
                    color: .green,
                    showDot: true
                )
            } else {
                PilotStatusPill(
                    text: L10n.t("未检测到运行中的 Antigravity", "Antigravity is not running", lang),
                    color: .secondary,
                    showDot: false,
                    systemImage: "moon.zzz"
                )
            }

            Spacer()

            if let profile = monitorStore.userProfile, !profile.email.isEmpty {
                PilotStatusPill(
                    text: "\(profile.email) · \(profile.tierName)",
                    color: .teal,
                    showDot: false
                )
            }

            Button {
                monitorStore.refreshLive()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .applyPulseSymbolEffect(monitorStore.isRefreshingLive)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(monitorStore.isRefreshingLive)
            .help(L10n.t("刷新实时监控", "Refresh live monitor", lang))
        }
    }

    private var emptyRunningState: some View {
        PilotCard(padding: 28, accentTint: .teal) {
            VStack(spacing: 14) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 60, height: 60)
                    .background(Color.teal.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                Text(L10n.t("Antigravity 当前未运行", "Antigravity Is Not Running", lang))
                    .font(.headline)

                Text(L10n.t(
                    "启动 Antigravity（或 Pilot 代理副本）后，这里将自动读取 ~/.gemini/antigravity/daemon/ 并直连本地回环服务展示上下文窗口与模型配额。",
                    "After launching Antigravity (or Pilot runtime), this view reads ~/.gemini/antigravity/daemon/ and connects to the local loopback service to show live context & model quotas.",
                    lang
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

                Button {
                    appModel.launchExistingRuntimeOnly()
                } label: {
                    Label(L10n.t("启动 Antigravity Pilot", "Launch Antigravity Pilot", lang), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var contextCard: some View {
        PilotCard(padding: 15) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.t("当前会话上下文", "Active Session Context", lang), systemImage: "cpu")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !monitorStore.sessions.isEmpty {
                        let topSessions = Array(monitorStore.sessions.prefix(12))
                        let displayedSessions: [SessionSummary] = {
                            if let pinnedId = monitorStore.pinnedCascadeId,
                               !topSessions.contains(where: { $0.id == pinnedId }),
                               let extra = monitorStore.sessions.first(where: { $0.id == pinnedId }) {
                                return topSessions + [extra]
                            }
                            return topSessions
                        }()
                        let autoTitle: String = {
                            let base = L10n.t("自动（最新会话）", "Auto (Latest)", lang)
                            if let first = monitorStore.sessions.first {
                                return "\(base) · \(first.title)"
                            }
                            return base
                        }()
                        Picker(
                            "",
                            selection: Binding(
                                get: { monitorStore.pinnedCascadeId ?? "" },
                                set: { monitorStore.selectSession($0.isEmpty ? nil : $0) }
                            )
                        ) {
                            Text(autoTitle).tag("")
                            ForEach(displayedSessions) { session in
                                Text(session.title).tag(session.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                }

                if let ctx = monitorStore.activeContext {
                    HStack(spacing: 16) {
                        PilotRingGauge(
                            fraction: ctx.usageFraction,
                            tint: contextTint(ctx.usageFraction),
                            size: 72,
                            lineWidth: 7
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(ctx.modelDisplayName)
                                    .font(.callout.weight(.semibold))
                                Spacer()
                                Text("\(TokenFormatting.compactTokens(ctx.activeContextTokens)) / \(TokenFormatting.compactTokens(ctx.contextLimitTokens))")
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }

                            GeometryReader { geo in
                                let limit = max(1, ctx.contextLimitTokens)
                                let cacheW = geo.size.width * min(1, Double(ctx.cacheReadTokens) / Double(limit))
                                let inputW = geo.size.width * min(1 - min(1, Double(ctx.cacheReadTokens) / Double(limit)), Double(ctx.inputTokens) / Double(limit))
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.08))
                                    HStack(spacing: 1.5) {
                                        if cacheW > 0 {
                                            Rectangle()
                                                .fill(Color.accentColor.opacity(0.75))
                                                .frame(width: cacheW)
                                        }
                                        if inputW > 0 {
                                            Rectangle()
                                                .fill(Color.orange)
                                                .frame(width: inputW)
                                        }
                                    }
                                    .clipShape(Capsule())
                                }
                            }
                            .frame(height: 8)

                            HStack(spacing: 12) {
                                legendDot(
                                    color: Color.accentColor.opacity(0.75),
                                    text: L10n.t(
                                        zhHans: "缓存命中 \(TokenFormatting.compactTokens(ctx.cacheReadTokens))",
                                        zhHant: "快取命中 \(TokenFormatting.compactTokens(ctx.cacheReadTokens))",
                                        en: "Cached \(TokenFormatting.compactTokens(ctx.cacheReadTokens))",
                                        ru: "Кэш \(TokenFormatting.compactTokens(ctx.cacheReadTokens))",
                                        lang
                                    )
                                )
                                legendDot(
                                    color: .orange,
                                    text: L10n.t(
                                        zhHans: "新增输入 \(TokenFormatting.compactTokens(ctx.inputTokens))",
                                        zhHant: "新增輸入 \(TokenFormatting.compactTokens(ctx.inputTokens))",
                                        en: "New In \(TokenFormatting.compactTokens(ctx.inputTokens))",
                                        ru: "Вход \(TokenFormatting.compactTokens(ctx.inputTokens))",
                                        lang
                                    )
                                )
                                legendDot(
                                    color: .green,
                                    text: L10n.t(
                                        zhHans: "输出 \(TokenFormatting.compactTokens(ctx.outputTokens))",
                                        zhHant: "輸出 \(TokenFormatting.compactTokens(ctx.outputTokens))",
                                        en: "Output \(TokenFormatting.compactTokens(ctx.outputTokens))",
                                        ru: "Выход \(TokenFormatting.compactTokens(ctx.outputTokens))",
                                        lang
                                    )
                                )
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            compactMetricTile(title: L10n.t("缓存命中率", "Cache Hit Rate", lang), value: "\(Int((ctx.cacheHitRatio * 100).rounded()))%")
                            compactMetricTile(title: L10n.t("首字延迟 (TTFT)", "TTFT", lang), value: ctx.timeToFirstTokenSec.map { String(format: "%.2f s", $0) } ?? "--")
                            compactMetricTile(title: L10n.t("输出速度", "Output Speed", lang), value: ctx.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "--")
                            compactMetricTile(title: L10n.t("思考 / 回复", "Thinking / Reply", lang), value: "\(TokenFormatting.compactTokens(ctx.thinkingOutputTokens)) / \(TokenFormatting.compactTokens(ctx.responseOutputTokens))")
                        }
                    }
                } else {
                    Text(L10n.t("当前选定会话暂无模型调用记录。", "No model usage recorded in the selected session.", lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func compactMetricTile(title: String, value: String) -> some View {
        PilotRecessedBox(padding: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
        }
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }

    private func contextTint(_ fraction: Double) -> Color {
        if fraction >= 0.85 { return .red }
        if fraction >= 0.65 { return .orange }
        return .accentColor
    }

    private var quotaSection: some View {
        PilotCard(padding: 15) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        L10n.t(
                            zhHans: "模型共享配额池（\(monitorStore.quotaPools.count) 组）",
                            zhHant: "模型共享配額池（\(monitorStore.quotaPools.count) 組）",
                            en: "Shared Model Quota Pools (\(monitorStore.quotaPools.count))",
                            ru: "Пулы квот моделей (\(monitorStore.quotaPools.count))",
                            lang
                        ),
                        systemImage: "square.stack.3d.up"
                    )
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                }

                if monitorStore.quotaPools.isEmpty {
                    Text(L10n.t("暂未获取到模型配额信息。", "No model quota information available yet.", lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach(monitorStore.quotaPools) { pool in
                            quotaPoolCard(pool)
                        }
                    }
                }
            }
        }
    }

    private func quotaPoolCard(_ pool: QuotaPoolGroup) -> some View {
        let isExpanded = expandedPoolIds.contains(pool.id)
        let tint: Color = pool.remainingPercent <= 15 ? .red : (pool.remainingPercent <= 35 ? .orange : .green)

        return PilotRecessedBox(padding: 11) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(pool.title)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(pool.resetCountdownText(lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(pool.remainingPercent)%")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .frame(width: 44, alignment: .trailing)
                }

                PilotLinearBar(fraction: pool.remainingFraction, tint: tint, height: 6.5)

                if pool.models.count > 1 {
                    Button {
                        if isExpanded {
                            expandedPoolIds.remove(pool.id)
                        } else {
                            expandedPoolIds.insert(pool.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text(L10n.t(
                                zhHans: "包含 \(pool.models.count) 个模型档位",
                                zhHant: "包含 \(pool.models.count) 個模型檔位",
                                en: "Includes \(pool.models.count) model tiers",
                                ru: "Моделей в пуле: \(pool.models.count)",
                                lang
                            ))
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        Text(pool.models.map(\.label).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
