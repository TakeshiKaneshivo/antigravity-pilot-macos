import Charts
import SwiftUI

enum UsageBreakdownDimension: String, CaseIterable, Identifiable {
    case model
    case project
    case session

    var id: String { rawValue }

    func localizedTitle(_ lang: AppLanguage) -> String {
        switch self {
        case .model:
            return L10n.t(zhHans: "按模型", zhHant: "按模型", en: "By Model", ru: "Модели", lang)
        case .project:
            return L10n.t(zhHans: "按项目", zhHant: "按專案", en: "By Project", ru: "Проекты", lang)
        case .session:
            return L10n.t(zhHans: "按会话", zhHant: "按工作階段", en: "By Session", ru: "Сессии", lang)
        }
    }
}

private struct BreakdownChartEntry: Identifiable {
    let id: String
    let displayName: String
    let totalTokens: Int
    let estimatedCostUSD: Double
}

struct UsageHeatmapView: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var monitorStore: MonitorStore

    @State private var selectedPeriod: UsagePeriod = .days30
    @State private var breakdownDimension: UsageBreakdownDimension = .model
    @State private var selectedDateKey: String?
    @State private var chartHoverDateKey: String?

    private var chartPalette: [Color] {
        PilotMorandiPalette.chartSeries(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerControls
            kpiGrid

            HStack(alignment: .top, spacing: 10) {
                heatmapCard
                    .frame(width: 304)
                dailyChartCard
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 168)

            breakdownCard
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var currentTotal: DailyUsageBucket {
        monitorStore.usageHistory.totalsByPeriod[selectedPeriod]
            ?? DailyUsageBucket(dateKey: "", inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0, cacheSavingsUSD: 0)
    }

    private var currentModels: [ModelUsageSummary] {
        monitorStore.usageHistory.modelSummariesByPeriod[selectedPeriod] ?? []
    }

    private var currentProjects: [ProjectUsageSummary] {
        monitorStore.usageHistory.projectSummariesByPeriod[selectedPeriod] ?? []
    }

    private var currentSessions: [SessionUsageSummary] {
        monitorStore.usageHistory.sessionSummariesByPeriod[selectedPeriod] ?? []
    }

    private var displayedModelEntries: [BreakdownChartEntry] {
        let items = currentModels.map {
            BreakdownChartEntry(id: $0.modelKey, displayName: $0.displayName, totalTokens: $0.totalTokens, estimatedCostUSD: $0.estimatedCostUSD)
        }
        return collapseTop5(items)
    }

    private var displayedProjectEntries: [BreakdownChartEntry] {
        let items = currentProjects.map { p in
            let name = p.projectKey == "__unassigned__"
                ? L10n.t(
                    zhHans: "未绑定工作区",
                    zhHant: "未綁定工作區",
                    en: "Unassigned Workspace",
                    ru: "Без проекта",
                    lang
                )
                : p.displayName
            return BreakdownChartEntry(id: p.projectKey, displayName: name, totalTokens: p.totalTokens, estimatedCostUSD: p.estimatedCostUSD)
        }
        return collapseTop5(items)
    }

    private func collapseTop5(_ items: [BreakdownChartEntry]) -> [BreakdownChartEntry] {
        guard items.count > 6 else { return items }
        let top5 = Array(items.prefix(5))
        let rest = items.dropFirst(5)
        let others = BreakdownChartEntry(
            id: "__others__",
            displayName: L10n.t(
                zhHans: "其他 (\(rest.count))",
                zhHant: "其他 (\(rest.count))",
                en: "Others (\(rest.count))",
                ru: "Прочие (\(rest.count))",
                lang
            ),
            totalTokens: rest.reduce(0) { $0 + $1.totalTokens },
            estimatedCostUSD: rest.reduce(0) { $0 + $1.estimatedCostUSD }
        )
        return top5 + [others]
    }

    private var headerControls: some View {
        let hist = monitorStore.usageHistory
        let archiveText: String = {
            if hist.cliArchiveCount > 0 {
                return "App \(hist.desktopArchiveCount) · CLI \(hist.cliArchiveCount)"
            }
            return L10n.t(
                zhHans: "已扫描 \(hist.scannedFilesCount) 个归档",
                zhHant: "已掃描 \(hist.scannedFilesCount) 個歸檔",
                en: "\(hist.scannedFilesCount) archives scanned",
                ru: "Логи: \(hist.scannedFilesCount)",
                lang
            )
        }()

        return HStack(spacing: 8) {
            Picker("", selection: $selectedPeriod) {
                ForEach(UsagePeriod.allCases) { period in
                    Text(period.localizedTitle(lang)).tag(period)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 270)

            Spacer()

            PilotStatusPill(
                text: archiveText,
                color: .secondary,
                showDot: false,
                systemImage: "doc.text.magnifyingglass"
            )

            Button {
                monitorStore.refreshHistory()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .applyPulseSymbolEffect(monitorStore.isRefreshingHistory)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(monitorStore.isRefreshingHistory)
            .help(L10n.t("重新扫描会话用量", "Rescan session transcripts", lang))
        }
    }

    private var kpiGrid: some View {
        let total = currentTotal
        let promptTotal = total.inputTokens + total.cacheReadTokens
        let cacheRate = promptTotal > 0 ? Int((Double(total.cacheReadTokens) / Double(promptTotal) * 100).rounded()) : 0

        let cacheSubtitle: String = {
            let base = L10n.t(
                zhHans: "命中 \(TokenFormatting.compactTokens(total.cacheReadTokens))",
                zhHant: "命中 \(TokenFormatting.compactTokens(total.cacheReadTokens))",
                en: "Cached \(TokenFormatting.compactTokens(total.cacheReadTokens))",
                ru: "Кэш \(TokenFormatting.compactTokens(total.cacheReadTokens))",
                lang
            )
            if total.cacheSavingsUSD >= 0.005 {
                let saved = TokenFormatting.usd(total.cacheSavingsUSD)
                return L10n.t(
                    zhHans: "\(base) · 省 \(saved)",
                    zhHant: "\(base) · 省 \(saved)",
                    en: "\(base) · Saved \(saved)",
                    ru: "\(base) · Эк. \(saved)",
                    lang
                )
            }
            return base
        }()

        let tierInfo = monitorStore.effectiveSubscriptionTier
        let costSubtitle: String = {
            if let monthlyUSD = tierInfo.monthlyReferenceUSD, monthlyUSD > 0 {
                let ratio = total.estimatedCostUSD / monthlyUSD
                switch tierInfo.tierKind {
                case .ultra:
                    return String(
                        format: L10n.t(
                            zhHans: "≈ %.1fx $249.99 Ultra 月费",
                            zhHant: "≈ %.1fx $249.99 Ultra 月費",
                            en: "≈ %.1fx $249.99 Ultra/mo",
                            ru: "≈ %.1fx $249.99 Ultra/мес",
                            lang
                        ),
                        ratio
                    )
                case .pro:
                    return String(
                        format: L10n.t(
                            zhHans: "≈ %.1fx $20 Pro 月费",
                            zhHant: "≈ %.1fx $20 Pro 月費",
                            en: "≈ %.1fx $20 Pro/mo",
                            ru: "≈ %.1fx $20 Pro/мес",
                            lang
                        ),
                        ratio
                    )
                case .free, .unknown:
                    break
                }
            }
            if tierInfo.tierKind == .free {
                return L10n.t(
                    zhHans: "Free 档 · 参考 API 单价",
                    zhHant: "Free 檔 · 參考 API 單價",
                    en: "Free tier · API reference",
                    ru: "Free · оценка по API",
                    lang
                )
            }
            return L10n.t(
                zhHans: "参考 API 公开单价",
                zhHant: "參考 API 公開單價",
                en: "Est. via public API pricing",
                ru: "Оценка по тарифам API",
                lang
            )
        }()

        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                PilotMetricTile(
                    title: L10n.t("总消耗 Token", "Total Tokens", lang),
                    value: TokenFormatting.compactTokens(total.totalTokens),
                    subtitle: L10n.t(
                        zhHans: "输入 \(TokenFormatting.compactTokens(total.inputTokens)) · 输出 \(TokenFormatting.compactTokens(total.outputTokens))",
                        zhHant: "輸入 \(TokenFormatting.compactTokens(total.inputTokens)) · 輸出 \(TokenFormatting.compactTokens(total.outputTokens))",
                        en: "In \(TokenFormatting.compactTokens(total.inputTokens)) · Out \(TokenFormatting.compactTokens(total.outputTokens))",
                        ru: "Вх \(TokenFormatting.compactTokens(total.inputTokens)) · Вых \(TokenFormatting.compactTokens(total.outputTokens))",
                        lang
                    ),
                    icon: "sparkles",
                    tint: PilotMorandiPalette.kpiTokens(colorScheme: colorScheme),
                    compact: true
                )
                PilotMetricTile(
                    title: L10n.t("缓存命中率", "Cache Hit Rate", lang),
                    value: "\(cacheRate)%",
                    subtitle: cacheSubtitle,
                    icon: "bolt.fill",
                    tint: PilotMorandiPalette.kpiCache(colorScheme: colorScheme),
                    compact: true
                )
                PilotMetricTile(
                    title: L10n.t("模型调用次数", "Model Calls", lang),
                    value: "\(total.requestCount)",
                    subtitle: L10n.t(
                        zhHans: "\(selectedPeriod.localizedTitle(lang)) PLANNER 轮次",
                        zhHant: "\(selectedPeriod.localizedTitle(lang)) PLANNER 輪次",
                        en: "\(selectedPeriod.localizedTitle(lang)) turns",
                        ru: "\(selectedPeriod.localizedTitle(lang)) шагов",
                        lang
                    ),
                    icon: "arrow.triangle.2.circlepath",
                    tint: PilotMorandiPalette.kpiCalls(colorScheme: colorScheme),
                    compact: true
                )
                PilotMetricTile(
                    title: L10n.t("估算 API 账单", "Est. API Cost", lang),
                    value: TokenFormatting.usd(total.estimatedCostUSD),
                    subtitle: costSubtitle,
                    icon: "dollarsign.circle.fill",
                    tint: PilotMorandiPalette.kpiCost(colorScheme: colorScheme),
                    compact: true
                )
            }
        }
    }

    private var heatmapCard: some View {
        let grid = HeatmapLayout.build20Weeks(buckets: monitorStore.usageHistory.dailyBuckets)
        let activeBucket = selectedDateKey.flatMap { key in
            monitorStore.usageHistory.dailyBuckets.first(where: { $0.dateKey == key })
        }

        return PilotCard(padding: 10, fillHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label(L10n.t("近 20 周热力图", "20-Week Heatmap", lang), systemImage: "calendar")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    HStack(spacing: 3) {
                        Text(L10n.t("低", "Less", lang))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        ForEach(0..<5, id: \.self) { level in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(heatmapColor(level: level))
                                .frame(width: 8, height: 8)
                        }
                        Text(L10n.t("高", "More", lang))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 5) {
                    VStack(spacing: 0) {
                        Text(L10n.t("一", "M", lang)).frame(height: 12)
                        Spacer(minLength: 0)
                        Text(L10n.t("三", "W", lang)).frame(height: 12)
                        Spacer(minLength: 0)
                        Text(L10n.t("五", "F", lang)).frame(height: 12)
                        Spacer(minLength: 13)
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 92)

                    GeometryReader { geo in
                        let cols = grid.weeks.count
                        let rows = 7
                        let spacing: CGFloat = 2
                        let cellSize = min(11.5, max(7, (geo.size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)))
                        let totalW = CGFloat(cols) * cellSize + CGFloat(cols - 1) * spacing
                        let originX = max(0, (geo.size.width - totalW) / 2)

                        Canvas { context, _ in
                            for (colIdx, week) in grid.weeks.enumerated() {
                                for (rowIdx, cell) in week.enumerated() {
                                    guard let cell else { continue }
                                    let x = originX + CGFloat(colIdx) * (cellSize + spacing)
                                    let y = CGFloat(rowIdx) * (cellSize + spacing)
                                    let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                                    let rounded = Path(roundedRect: rect, cornerRadius: 2.5)
                                    context.fill(rounded, with: .color(heatmapColor(level: cell.level)))
                                    if cell.dateKey == selectedDateKey {
                                        context.stroke(rounded, with: .color(.primary), lineWidth: 1.3)
                                    }
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let col = Int(floor((value.location.x - originX) / (cellSize + spacing)))
                                    let row = Int(floor(value.location.y / (cellSize + spacing)))
                                    if col >= 0, col < cols, row >= 0, row < rows,
                                       let cell = grid.weeks[col][row] {
                                        selectedDateKey = cell.dateKey
                                    }
                                }
                        )
                    }
                    .frame(height: 92)
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    if let activeBucket {
                        Text(L10n.t(
                            zhHans: "\(activeBucket.dateKey)：\(TokenFormatting.compactTokens(activeBucket.totalTokens)) · \(activeBucket.requestCount)次 · \(TokenFormatting.usd(activeBucket.estimatedCostUSD))",
                            zhHant: "\(activeBucket.dateKey)：\(TokenFormatting.compactTokens(activeBucket.totalTokens)) · \(activeBucket.requestCount)次 · \(TokenFormatting.usd(activeBucket.estimatedCostUSD))",
                            en: "\(activeBucket.dateKey): \(TokenFormatting.compactTokens(activeBucket.totalTokens)) · \(activeBucket.requestCount) req · \(TokenFormatting.usd(activeBucket.estimatedCostUSD))",
                            ru: "\(activeBucket.dateKey): \(TokenFormatting.compactTokens(activeBucket.totalTokens)) · \(activeBucket.requestCount) вызов. · \(TokenFormatting.usd(activeBucket.estimatedCostUSD))",
                            lang
                        ))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else {
                        Text(L10n.t("点击方格查看单日明细", "Click a cell for day details", lang))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(L10n.t("本地自然日", "Local day", lang))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func heatmapColor(level: Int) -> Color {
        PilotMorandiPalette.heatmapColor(level: level, colorScheme: colorScheme)
    }

    private var dailyChartCard: some View {
        let recent = Array(monitorStore.usageHistory.dailyBuckets.suffix(14))

        return PilotCard(padding: 10, fillHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label(L10n.t("近 14 日趋势", "14-Day Trend", lang), systemImage: "chart.bar.fill")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if let hovered = chartHoverDateKey.flatMap({ k in recent.first(where: { $0.dateKey == k }) }) {
                        Text("\(String(hovered.dateKey.suffix(5))) · \(TokenFormatting.compactTokens(hovered.totalTokens)) · \(TokenFormatting.usd(hovered.estimatedCostUSD))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(L10n.t("悬停查看当日", "Hover for details", lang))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                if recent.isEmpty {
                    Text(L10n.t("暂无近 14 日用量记录", "No usage data in the last 14 days", lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    baseDailyChart(recent: recent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func sparseAxisLabels(for recent: [DailyUsageBucket]) -> [String] {
        let labels = recent.map { String($0.dateKey.suffix(5)) }
        guard labels.count > 4 else { return labels }
        let candidateIndices = [0, labels.count / 3, (labels.count * 2) / 3, labels.count - 1]
        var seen = Set<String>()
        var result: [String] = []
        for idx in candidateIndices where idx >= 0 && idx < labels.count {
            let lbl = labels[idx]
            if seen.insert(lbl).inserted {
                result.append(lbl)
            }
        }
        return result
    }

    @ViewBuilder
    private func baseDailyChart(recent: [DailyUsageBucket]) -> some View {
        let xLabels = sparseAxisLabels(for: recent)
        let chart = Chart(recent) { day in
            BarMark(
                x: .value("Date", String(day.dateKey.suffix(5))),
                y: .value("Tokens", day.totalTokens)
            )
            .foregroundStyle(
                PilotMorandiPalette.trendBarGradient(
                    colorScheme: colorScheme,
                    isHighlighted: chartHoverDateKey == day.dateKey
                )
            )
            .cornerRadius(3)
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { val in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                AxisValueLabel {
                    if let n = val.as(Int.self) {
                        Text(TokenFormatting.compactTokensShort(n))
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xLabels) { val in
                AxisValueLabel {
                    if let s = val.as(String.self) {
                        Text(s)
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                    }
                }
            }
        }

        if #available(macOS 14, *) {
            chart.chartXSelection(value: Binding(
                get: { chartHoverDateKey.map { String($0.suffix(5)) } },
                set: { short in
                    chartHoverDateKey = short.flatMap { s in recent.first(where: { $0.dateKey.hasSuffix(s) })?.dateKey }
                }
            ))
        } else {
            chart
        }
    }

    private var breakdownCard: some View {
        PilotCard(padding: 11, fillHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Picker("", selection: $breakdownDimension) {
                        ForEach(UsageBreakdownDimension.allCases) { dim in
                            Text(dim.localizedTitle(lang)).tag(dim)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)

                    Spacer()

                    Text(L10n.t("参考 API 定价估算，非实际扣费", "Estimated via API pricing, not actual billing", lang))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                switch breakdownDimension {
                case .model:
                    donutBreakdownBody(entries: displayedModelEntries)
                case .project:
                    donutBreakdownBody(entries: displayedProjectEntries)
                case .session:
                    sessionBreakdownBody(sessions: Array(currentSessions.prefix(20)))
                }
            }
        }
    }

    @ViewBuilder
    private func donutBreakdownBody(entries: [BreakdownChartEntry]) -> some View {
        let maxTokens = max(1, entries.map(\.totalTokens).max() ?? 1)
        if entries.isEmpty {
            Text(L10n.t("所选周期暂无模型调用记录。", "No model usage recorded in this period.", lang))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            HStack(alignment: .center, spacing: 16) {
                if #available(macOS 14, *) {
                    Chart(entries) { item in
                        SectorMark(
                            angle: .value("Tokens", max(1, item.totalTokens)),
                            innerRadius: .ratio(0.60),
                            angularInset: 1.5
                        )
                        .foregroundStyle(by: .value("Item", item.displayName))
                    }
                    .chartForegroundStyleScale(
                        domain: entries.map(\.displayName),
                        range: Array(chartPalette.prefix(entries.count))
                    )
                    .chartLegend(.hidden)
                    .frame(width: 104, height: 104)
                }

                VStack(spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, item in
                        let rowColor = chartPalette[idx % chartPalette.count]
                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(rowColor)
                                    .frame(width: 7, height: 7)
                                Text(item.displayName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .frame(width: 136, alignment: .leading)

                            PilotLinearBar(
                                fraction: Double(item.totalTokens) / Double(maxTokens),
                                tint: rowColor,
                                height: 5.5
                            )

                            Text(TokenFormatting.compactTokens(item.totalTokens))
                                .font(.system(.caption, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 54, alignment: .trailing)

                            Text(TokenFormatting.usd(item.estimatedCostUSD))
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func sessionBreakdownBody(sessions: [SessionUsageSummary]) -> some View {
        let maxTokens = max(1, sessions.map(\.totalTokens).max() ?? 1)
        if sessions.isEmpty {
            Text(L10n.t("所选周期暂无会话调用记录。", "No session usage recorded in this period.", lang))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, item in
                        let rowColor = chartPalette[idx % chartPalette.count]
                        HStack(spacing: 8) {
                            Text(item.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let project = item.projectName, !project.isEmpty {
                                Text(project)
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.primary.opacity(0.06))
                                    .foregroundStyle(.secondary)
                                    .clipShape(Capsule())
                                    .lineLimit(1)
                            }

                            if item.clientSource == .cli {
                                Text("CLI")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(rowColor.opacity(0.18))
                                    .foregroundStyle(rowColor)
                                    .clipShape(Capsule())
                            }

                            PilotLinearBar(
                                fraction: Double(item.totalTokens) / Double(maxTokens),
                                tint: rowColor,
                                height: 4.5
                            )
                            .frame(width: 68)

                            Text(TokenFormatting.compactTokens(item.totalTokens))
                                .font(.system(.caption, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)

                            Text(TokenFormatting.usd(item.estimatedCostUSD))
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                                .frame(width: 54, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

private enum HeatmapLayout {
    struct Cell {
        let dateKey: String
        let level: Int
    }

    struct GridData {
        let weeks: [[Cell?]]
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    static func build20Weeks(buckets: [DailyUsageBucket]) -> GridData {
        let map = Dictionary(uniqueKeysWithValues: buckets.map { ($0.dateKey, $0.totalTokens) })
        let nonZero = buckets.map(\.totalTokens).filter { $0 > 0 }.sorted()
        let q1 = nonZero.isEmpty ? 1 : nonZero[nonZero.count / 4]
        let q2 = nonZero.isEmpty ? 1 : nonZero[nonZero.count / 2]
        let q3 = nonZero.isEmpty ? 1 : nonZero[(nonZero.count * 3) / 4]

        let cal = Calendar(identifier: .gregorian)
        let df = dayFormatter

        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today) // 1=Sun ... 7=Sat
        let daysFromMonday = (weekday + 5) % 7
        let currentMonday = cal.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today
        let startMonday = cal.date(byAdding: .weekOfYear, value: -19, to: currentMonday) ?? currentMonday

        var weeks: [[Cell?]] = []
        for w in 0..<20 {
            var col: [Cell?] = []
            for d in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: w * 7 + d, to: startMonday) else {
                    col.append(nil)
                    continue
                }
                if date > today {
                    col.append(nil)
                    continue
                }
                let key = df.string(from: date)
                let tokens = map[key] ?? 0
                let level: Int
                if tokens <= 0 {
                    level = 0
                } else if tokens <= q1 {
                    level = 1
                } else if tokens <= q2 {
                    level = 2
                } else if tokens <= q3 {
                    level = 3
                } else {
                    level = 4
                }
                col.append(Cell(dateKey: key, level: level))
            }
            weeks.append(col)
        }
        return GridData(weeks: weeks)
    }
}
