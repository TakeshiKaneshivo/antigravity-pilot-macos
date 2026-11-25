import Charts
import SwiftUI

struct UsageHeatmapView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var monitorStore: MonitorStore

    @State private var selectedPeriod: UsagePeriod = .days30
    @State private var selectedDateKey: String?
    @State private var chartHoverDateKey: String?

    private let chartPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]

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

            modelBreakdownCard
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var currentTotal: DailyUsageBucket {
        monitorStore.usageHistory.totalsByPeriod[selectedPeriod]
            ?? DailyUsageBucket(dateKey: "", inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0)
    }

    private var currentModels: [ModelUsageSummary] {
        monitorStore.usageHistory.modelSummariesByPeriod[selectedPeriod] ?? []
    }

    private var displayedModels: [ModelUsageSummary] {
        let models = currentModels
        guard models.count > 6 else { return models }
        let top5 = Array(models.prefix(5))
        let rest = models.dropFirst(5)
        let others = ModelUsageSummary(
            modelKey: "__others__",
            displayName: L10n.t(
                zhHans: "其他 (\(rest.count))",
                zhHant: "其他 (\(rest.count))",
                en: "Others (\(rest.count))",
                ru: "Прочие (\(rest.count))",
                lang
            ),
            inputTokens: rest.reduce(0) { $0 + $1.inputTokens },
            cacheReadTokens: rest.reduce(0) { $0 + $1.cacheReadTokens },
            outputTokens: rest.reduce(0) { $0 + $1.outputTokens },
            requestCount: rest.reduce(0) { $0 + $1.requestCount },
            estimatedCostUSD: rest.reduce(0) { $0 + $1.estimatedCostUSD }
        )
        return top5 + [others]
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
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
                text: L10n.t(
                    zhHans: "已扫描 \(monitorStore.usageHistory.scannedFilesCount) 个归档",
                    zhHant: "已掃描 \(monitorStore.usageHistory.scannedFilesCount) 個歸檔",
                    en: "\(monitorStore.usageHistory.scannedFilesCount) archives scanned",
                    ru: "Логи: \(monitorStore.usageHistory.scannedFilesCount)",
                    lang
                ),
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
        let subRatio = total.estimatedCostUSD / PricingCatalog.proSubscriptionMonthlyUSD

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
                    tint: .blue,
                    compact: true
                )
                PilotMetricTile(
                    title: L10n.t("缓存命中率", "Cache Hit Rate", lang),
                    value: "\(cacheRate)%",
                    subtitle: L10n.t(
                        zhHans: "命中 \(TokenFormatting.compactTokens(total.cacheReadTokens))",
                        zhHant: "命中 \(TokenFormatting.compactTokens(total.cacheReadTokens))",
                        en: "Cached \(TokenFormatting.compactTokens(total.cacheReadTokens))",
                        ru: "Кэш \(TokenFormatting.compactTokens(total.cacheReadTokens))",
                        lang
                    ),
                    icon: "bolt.fill",
                    tint: .teal,
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
                    tint: .indigo,
                    compact: true
                )
                PilotMetricTile(
                    title: L10n.t("估算 API 账单", "Est. API Cost", lang),
                    value: TokenFormatting.usd(total.estimatedCostUSD),
                    subtitle: String(
                        format: L10n.t("≈ %.1fx $20 Pro 月费", "≈ %.1fx $20 Pro/mo", lang),
                        subRatio
                    ),
                    icon: "dollarsign.circle.fill",
                    tint: .green,
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
                                    let col = Int((value.location.x - originX) / (cellSize + spacing))
                                    let row = Int(value.location.y / (cellSize + spacing))
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
        switch level {
        case 0: return Color.primary.opacity(0.07)
        case 1: return Color.green.opacity(0.28)
        case 2: return Color.green.opacity(0.50)
        case 3: return Color.green.opacity(0.75)
        default: return Color.green
        }
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
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.65), Color.accentColor],
                    startPoint: .bottom,
                    endPoint: .top
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

    private var modelBreakdownCard: some View {
        let models = displayedModels
        let maxTokens = max(1, models.map(\.totalTokens).max() ?? 1)

        return PilotCard(padding: 11, fillHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        L10n.t(
                            zhHans: "按模型用量与预估费用（\(selectedPeriod.localizedTitle(lang))）",
                            zhHant: "按模型用量與預估費用（\(selectedPeriod.localizedTitle(lang))）",
                            en: "Usage & Est. Cost by Model (\(selectedPeriod.localizedTitle(lang)))",
                            ru: "По моделям (\(selectedPeriod.localizedTitle(lang)))",
                            lang
                        ),
                        systemImage: "chart.pie.fill"
                    )
                    .font(.caption.weight(.semibold))
                    Spacer()
                    Text(L10n.t("参考 API 定价估算，非实际扣费", "Estimated via API pricing, not actual billing", lang))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if models.isEmpty {
                    Text(L10n.t("所选周期暂无模型调用记录。", "No model usage recorded in this period.", lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        if #available(macOS 14, *) {
                            Chart(models) { item in
                                SectorMark(
                                    angle: .value("Tokens", max(1, item.totalTokens)),
                                    innerRadius: .ratio(0.60),
                                    angularInset: 1.5
                                )
                                .foregroundStyle(by: .value("Model", item.displayName))
                            }
                            .chartForegroundStyleScale(
                                domain: models.map(\.displayName),
                                range: Array(chartPalette.prefix(models.count))
                            )
                            .chartLegend(.hidden)
                            .frame(width: 104, height: 104)
                        }

                        VStack(spacing: 6) {
                            ForEach(Array(models.enumerated()), id: \.element.id) { idx, item in
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
                                    .frame(width: 124, alignment: .leading)

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
