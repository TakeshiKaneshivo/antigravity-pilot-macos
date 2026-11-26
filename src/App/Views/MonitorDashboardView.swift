import SwiftUI

struct MonitorDashboardView: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chartPalette) private var chartPalettePreset
    @ObservedObject var appModel: AppModel
    @ObservedObject var monitorStore: MonitorStore

    @State private var expandedPoolIds: Set<String> = []
    @State private var isBreakdownExpanded = false
    @State private var isStepsExpanded = false
    @State private var showAllSteps = false

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
                    if let ctx = monitorStore.activeContext, !ctx.recentSteps.isEmpty {
                        stepsCard(ctx)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
    }

    private var headerStrip: some View {
        HStack(spacing: 8) {
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
                if monitorStore.activeRunningSessionCount > 0 {
                    let count = monitorStore.activeRunningSessionCount
                    PilotStatusPill(
                        text: L10n.t(
                            zhHans: "\(count) 运行中",
                            zhHant: "\(count) 執行中",
                            en: "\(count) running",
                            ru: "\(count) активн.",
                            lang
                        ),
                        color: .teal,
                        showDot: true
                    )
                }
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
                monitorStore.refreshLive(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .applyPulseSymbolEffect(monitorStore.isRefreshingLive)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

    private func sessionPickerTitle(_ session: SessionSummary) -> String {
        let runningDot = session.isRunning ? "● " : ""
        if session.isSubagent {
            let role = session.agentRole ?? L10n.t(zhHans: "子代理", zhHant: "子代理", en: "Subagent", ru: "Субагент", lang)
            let isShortFallback = session.title.caseInsensitiveCompare(String(session.id.prefix(8))) == .orderedSame
            if isShortFallback && session.agentRole != nil {
                return "\(runningDot)↳ \(role)"
            }
            return "\(runningDot)↳ [\(role)] \(session.title)"
        }
        if let ws = session.workspaceName, !ws.isEmpty {
            return "\(runningDot)[\(ws)] \(session.title)"
        }
        return "\(runningDot)\(session.title)"
    }

    private var contextCard: some View {
        PilotCard(padding: 15) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.t("当前会话上下文", "Active Session Context", lang), systemImage: "cpu")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !monitorStore.sessions.isEmpty {
                        let topSessions = Array(monitorStore.sessions.prefix(16))
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
                                Text(sessionPickerTitle(session)).tag(session.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
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
                            compactMetricTile(
                                title: L10n.t("缓存命中率", "Cache Hit Rate", lang),
                                value: "\(Int((ctx.cacheHitRatio * 100).rounded()))%",
                                subtitle: L10n.t(
                                    zhHans: "思/答 \(TokenFormatting.compactTokensShort(ctx.thinkingOutputTokens))/\(TokenFormatting.compactTokensShort(ctx.responseOutputTokens))",
                                    zhHant: "思/答 \(TokenFormatting.compactTokensShort(ctx.thinkingOutputTokens))/\(TokenFormatting.compactTokensShort(ctx.responseOutputTokens))",
                                    en: "Thk/Rep \(TokenFormatting.compactTokensShort(ctx.thinkingOutputTokens))/\(TokenFormatting.compactTokensShort(ctx.responseOutputTokens))",
                                    ru: "Мыс/Отв \(TokenFormatting.compactTokensShort(ctx.thinkingOutputTokens))/\(TokenFormatting.compactTokensShort(ctx.responseOutputTokens))",
                                    lang
                                )
                            )
                            compactMetricTile(
                                title: L10n.t("首字延迟 (TTFT)", "TTFT", lang),
                                value: ctx.timeToFirstTokenSec.map { String(format: "%.2f s", $0) } ?? "--",
                                subtitle: ctx.sessionAvgTTFTSec.map {
                                    L10n.t(
                                        zhHans: String(format: "均 %.2f s", $0),
                                        zhHant: String(format: "均 %.2f s", $0),
                                        en: String(format: "Avg %.2f s", $0),
                                        ru: String(format: "Ср. %.2f s", $0),
                                        lang
                                    )
                                }
                            )
                            compactMetricTile(
                                title: L10n.t("输出速度", "Output Speed", lang),
                                value: ctx.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "--",
                                subtitle: ctx.sessionAvgTokensPerSecond.map {
                                    L10n.t(
                                        zhHans: String(format: "均 %.1f t/s", $0),
                                        zhHant: String(format: "均 %.1f t/s", $0),
                                        en: String(format: "Avg %.1f t/s", $0),
                                        ru: String(format: "Ср. %.1f t/s", $0),
                                        lang
                                    )
                                }
                            )
                            compactMetricTile(
                                title: L10n.t(zhHans: "本会话费用", zhHant: "本工作階段費用", en: "Session Cost", ru: "Цена сессии", lang),
                                value: TokenFormatting.usd(ctx.sessionTotalCostUSD),
                                subtitle: L10n.t(
                                    zhHans: "共 \(ctx.sessionStepCount) 步",
                                    zhHant: "共 \(ctx.sessionStepCount) 步",
                                    en: "\(ctx.sessionStepCount) steps",
                                    ru: "\(ctx.sessionStepCount) шаг.",
                                    lang
                                )
                            )
                        }
                    }

                    if !ctx.contextBreakdown.isEmpty {
                        contextBreakdownSection(ctx.contextBreakdown)
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

    private func contextBreakdownSection(_ items: [ContextBreakdownItem]) -> some View {
        let palette = PilotMorandiPalette.contextBreakdownColors(preset: chartPalettePreset, colorScheme: colorScheme)
        let topSummary = items.prefix(3).map { item in
            "\(item.category.localizedTitle(lang)) \(Int((item.fraction * 100).rounded()))%"
        }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(items) { item in
                        let w = max(2, geo.size.width * item.fraction)
                        Rectangle()
                            .fill(palette[item.category.colorIndex % palette.count])
                            .frame(width: w)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isBreakdownExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isBreakdownExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(L10n.t(
                        zhHans: "上下文构成",
                        zhHant: "上下文構成",
                        en: "Context Breakdown",
                        ru: "Состав контекста",
                        lang
                    ))
                    .font(.caption2.weight(.semibold))
                    if !isBreakdownExpanded && !topSummary.isEmpty {
                        Text("· \(topSummary)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isBreakdownExpanded {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 5) {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(palette[item.category.colorIndex % palette.count])
                                .frame(width: 6.5, height: 6.5)
                            Text(item.category.localizedTitle(lang))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(TokenFormatting.compactTokens(item.tokens)) · \(Int((item.fraction * 100).rounded()))%")
                                .font(.system(.caption2, design: .rounded).weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 2)
    }

    private func compactMetricTile(title: String, value: String, subtitle: String? = nil) -> some View {
        PilotRecessedBox(padding: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
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
                    if pool.buckets.count < 2 {
                        Text(pool.resetCountdownText(lang))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(pool.remainingPercent)%")
                            .font(.system(.callout, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                            .frame(width: 44, alignment: .trailing)
                    } else if pool.models.count > 1 {
                        Button {
                            if isExpanded {
                                expandedPoolIds.remove(pool.id)
                            } else {
                                expandedPoolIds.insert(pool.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(L10n.t(
                                    zhHans: "包含 \(pool.models.count) 个模型档位",
                                    zhHant: "包含 \(pool.models.count) 個模型檔位",
                                    en: "Includes \(pool.models.count) model tiers",
                                    ru: "Моделей в пуле: \(pool.models.count)",
                                    lang
                                ))
                                .font(.caption2)
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if pool.buckets.count >= 2 {
                    HStack(spacing: 12) {
                        ForEach(pool.buckets.prefix(2)) { bucket in
                            let bTint: Color = bucket.remainingPercent <= 15 ? .red : (bucket.remainingPercent <= 35 ? .orange : .green)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text(bucket.windowKind.shortLabel(lang))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Text(bucket.shortCountdownText(lang))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                    Text("\(bucket.remainingPercent)%")
                                        .font(.system(.caption, design: .rounded).weight(.bold))
                                        .monospacedDigit()
                                        .foregroundStyle(bTint)
                                }
                                PilotLinearBar(fraction: bucket.remainingFraction, tint: bTint, height: 6)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    PilotLinearBar(fraction: pool.remainingFraction, tint: tint, height: 6.5)
                }

                if pool.buckets.count < 2 && pool.models.count > 1 {
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
                }

                if isExpanded && pool.models.count > 1 {
                    Text(pool.models.map(\.label).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stepsCard(_ ctx: SessionContextSnapshot) -> some View {
        let visibleSteps = showAllSteps ? ctx.recentSteps : Array(ctx.recentSteps.prefix(20))
        let avgText = ctx.sessionAvgTokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "--"

        return PilotCard(padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isStepsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isStepsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Label(
                            L10n.t(
                                zhHans: "调用步骤明细（\(ctx.sessionStepCount) 步 · 均速 \(avgText) · \(TokenFormatting.usd(ctx.sessionTotalCostUSD))）",
                                zhHant: "呼叫步驟明細（\(ctx.sessionStepCount) 步 · 均速 \(avgText) · \(TokenFormatting.usd(ctx.sessionTotalCostUSD))）",
                                en: "Step Details (\(ctx.sessionStepCount) steps · Avg \(avgText) · \(TokenFormatting.usd(ctx.sessionTotalCostUSD)))",
                                ru: "Шаги вызовов (\(ctx.sessionStepCount) · Ср. \(avgText) · \(TokenFormatting.usd(ctx.sessionTotalCostUSD)))",
                                lang
                            ),
                            systemImage: "list.bullet.rectangle"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                        Spacer()

                        if ctx.anomalyStepCount > 0 {
                            PilotStatusPill(
                                text: L10n.t(
                                    zhHans: "\(ctx.anomalyStepCount) 异常",
                                    zhHant: "\(ctx.anomalyStepCount) 異常",
                                    en: "\(ctx.anomalyStepCount) anomaly",
                                    ru: "\(ctx.anomalyStepCount) сбоев",
                                    lang
                                ),
                                color: .orange,
                                showDot: false
                            )
                        }
                    }
                }
                .buttonStyle(.plain)

                if isStepsExpanded {
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Text("#").frame(width: 28, alignment: .leading)
                            Text(L10n.t("模型", "Model", lang)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(L10n.t(zhHans: "上下文", zhHant: "上下文", en: "Context", ru: "Контекст", lang)).frame(width: 62, alignment: .trailing)
                            Text(L10n.t(zhHans: "输出", zhHant: "輸出", en: "Output", ru: "Выход", lang)).frame(width: 56, alignment: .trailing)
                            Text(L10n.t(zhHans: "TTFT / 速率", zhHant: "TTFT / 速率", en: "TTFT / TPS", ru: "TTFT / Скор.", lang)).frame(width: 96, alignment: .trailing)
                            Text(L10n.t(zhHans: "费用", zhHant: "費用", en: "Cost", ru: "Цена", lang)).frame(width: 54, alignment: .trailing)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)

                        Divider()

                        ForEach(visibleSteps) { step in
                            stepRow(step)
                        }

                        if ctx.recentSteps.count > 20 && !showAllSteps {
                            Button {
                                showAllSteps = true
                            } label: {
                                Text(L10n.t(
                                    zhHans: "显示全部最近 \(ctx.recentSteps.count) 步",
                                    zhHant: "顯示全部最近 \(ctx.recentSteps.count) 步",
                                    en: "Show all \(ctx.recentSteps.count) recent steps",
                                    ru: "Показать все \(ctx.recentSteps.count) шагов",
                                    lang
                                ))
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    private func stepRow(_ step: SessionStepItem) -> some View {
        let stripColor: Color = step.anomalyKind != nil ? .orange : (step.isCompactionStep ? .purple : .clear)
        let ttftStr = step.timeToFirstTokenSec.map { String(format: "%.1fs", $0) } ?? "--"
        let tpsStr = step.tokensPerSecond.map { String(format: "%.0f", $0) } ?? "--"

        return HStack(spacing: 6) {
            Rectangle()
                .fill(stripColor)
                .frame(width: 2.5, height: 16)
                .clipShape(Capsule())

            Text("\(step.stepNumber)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            HStack(spacing: 4) {
                Text(step.modelDisplayName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                if step.isCompactionStep {
                    Text(L10n.t(zhHans: "压缩", zhHant: "壓縮", en: "Compact", ru: "Сжатие", lang))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.14))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
                if let kind = step.anomalyKind {
                    Text(kind.localizedLabel(lang))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.16))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(TokenFormatting.compactTokens(step.activeContextTokens))
                .font(.system(.caption2, design: .rounded))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)

            Text(TokenFormatting.compactTokens(step.outputTokens))
                .font(.system(.caption2, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)

            Text("\(ttftStr) · \(tpsStr)/s")
                .font(.system(.caption2, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)

            Text(TokenFormatting.usd(step.estimatedCostUSD))
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            step.anomalyKind != nil
                ? Color.orange.opacity(0.06)
                : (step.isCompactionStep ? Color.purple.opacity(0.05) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help(step.anomalyExcerpt ?? "")
    }
}
