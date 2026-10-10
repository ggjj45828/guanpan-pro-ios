import SwiftUI
import Charts

private struct IndicatorPoint: Identifiable {
    var date: String
    var value: Double
    var id: String { date }
}

struct MarketChartView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var range = 120
    @State private var isLoading = false
    @State private var message = ""
    @State private var backtestCapital = "100000"
    @State private var backtestFeePercent = "0.03"
    @State private var backtestResult: StrategyBacktestResult?
    @State private var backtestMessage = ""

    private var allBars: [DailyBar] { store.dailyBars[holding.code] ?? [] }
    private var bars: [DailyBar] { Array(allBars.suffix(range)) }
    private var latest: DailyBar? { bars.last }
    private func average(_ window: Int) -> [IndicatorPoint] {
        guard bars.count >= window else { return [] }
        return bars.indices.compactMap { index in
            guard index + 1 >= window else { return nil }
            let values = bars[(index + 1 - window)...index].map(\.close)
            return IndicatorPoint(date: bars[index].date, value: values.reduce(0, +) / Double(window))
        }
    }
    private var drawdown: Double? {
        guard !bars.isEmpty else { return nil }
        var peak = bars[0].close
        var worst = 0.0
        for bar in bars { peak = max(peak, bar.close); worst = min(worst, bar.close / peak - 1) }
        return worst
    }
    private var percentile: Double? {
        guard let latest else { return nil }
        let prices = bars.map(\.close)
        guard !prices.isEmpty else { return nil }
        return Double(prices.filter { $0 <= latest.close }.count) / Double(prices.count) * 100
    }
    private var rsi14: Double? {
        guard bars.count >= 15 else { return nil }
        let closes = bars.suffix(15).map(\.close)
        let changes = (1..<closes.count).map { closes[$0] - closes[$0 - 1] }
        let gains = changes.map { max(0, $0) }.reduce(0, +) / 14
        let losses = changes.map { max(0, -$0) }.reduce(0, +) / 14
        if losses == 0 { return gains == 0 ? 50 : 100 }
        return 100 - 100 / (1 + gains / losses)
    }
    private var macd: (line: Double, signal: Double, histogram: Double)? {
        guard bars.count >= 35 else { return nil }
        let closes = bars.map(\.close)
        var ema12 = closes[0], ema26 = closes[0]
        var lines: [Double] = []
        for (index, close) in closes.enumerated() {
            if index > 0 { ema12 += (2.0 / 13.0) * (close - ema12); ema26 += (2.0 / 27.0) * (close - ema26) }
            if index >= 25 { lines.append(ema12 - ema26) }
        }
        guard let first = lines.first else { return nil }
        var signal = first
        for line in lines.dropFirst() { signal += 0.2 * (line - signal) }
        let line = lines[lines.count - 1]
        return (line, signal, 2 * (line - signal))
    }
    private var ruleAlerts: [String] {
        guard let latest, bars.count >= 2 else { return [] }
        var alerts: [String] = []
        let previous = bars[bars.count - 2]
        let dailyChange = latest.close / previous.close - 1
        if dailyChange <= -0.05 { alerts.append("单日收盘跌幅达到 5%") }
        if dailyChange >= 0.05 { alerts.append("单日收盘涨幅达到 5%") }
        let ma20 = average(20)
        if ma20.count >= 2 {
            let priorMA = ma20[ma20.count - 2].value, currentMA = ma20[ma20.count - 1].value
            if previous.close >= priorMA && latest.close < currentMA { alerts.append("收盘价下穿 MA20") }
            if previous.close <= priorMA && latest.close > currentMA { alerts.append("收盘价上穿 MA20") }
        }
        if let drawdown, drawdown <= -0.10 { alerts.append("所选区间最大回撤达到 10%") }
        if bars.count >= 21 {
            let referenceVolume = bars.suffix(21).dropLast().map(\.volume).reduce(0, +) / 20
            if referenceVolume > 0 && latest.volume >= referenceVolume * 2 && abs(dailyChange) >= 0.03 {
                alerts.append("成交量达到前 20 日均量 2 倍且单日波动达到 3%")
            }
        }
        return alerts
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("区间", selection: $range) {
                        Text("60日").tag(60); Text("120日").tag(120); Text("250日").tag(250); Text("640日").tag(640)
                    }.pickerStyle(.segmented)
                    if bars.count > 1 {
                        Chart {
                            ForEach(bars) { bar in
                                let candleColor = bar.close >= bar.open ? Color.red : Color.green
                                RuleMark(x: .value("日期", bar.date), yStart: .value("最低", bar.low), yEnd: .value("最高", bar.high))
                                    .foregroundStyle(candleColor).lineStyle(StrokeStyle(lineWidth: 1))
                                RectangleMark(x: .value("日期", bar.date), yStart: .value("开盘", bar.open), yEnd: .value("收盘", bar.close), width: .fixed(3))
                                    .foregroundStyle(candleColor)
                            }
                            ForEach(average(5)) { point in
                                LineMark(x: .value("日期", point.date), y: .value("MA5", point.value))
                                    .foregroundStyle(Color.cyan).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            }
                            ForEach(average(20)) { point in
                                LineMark(x: .value("日期", point.date), y: .value("MA20", point.value))
                                    .foregroundStyle(Color.orange).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                            ForEach(average(60)) { point in
                                LineMark(x: .value("日期", point.date), y: .value("MA60", point.value))
                                    .foregroundStyle(Color.purple).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            }
                        }
                        .frame(height: 240)
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                        HStack(spacing: 12) {
                            Label("日K", systemImage: "chart.bar.xaxis").foregroundStyle(.red)
                            Label("MA5", systemImage: "line.diagonal").foregroundStyle(.cyan)
                            Label("MA20", systemImage: "line.diagonal").foregroundStyle(.orange)
                            Label("MA60", systemImage: "line.diagonal").foregroundStyle(.purple)
                        }.font(.caption2)
                    } else {
                        ContentUnavailableView("暂无日线", systemImage: "chart.xyaxis.line", description: Text("联网获取历史行情，或在备份中导入已有日线缓存。"))
                    }
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button { Task { await load(force: true) } } label: {
                        Label(isLoading ? "正在更新…" : "更新历史日线", systemImage: "arrow.clockwise")
                    }.disabled(isLoading)
                    Text("数据：腾讯前复权日线。MA5/20/60、RSI14、MACD、区间分位与最大回撤由本机计算，仅作历史描述，不是价格预测或估值。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("\(holding.name) · \(holding.code)") }
                if let latest {
                    Section("历史指标") {
                        LabeledContent("最新收盘（\(latest.date)）", value: latest.close, format: .number.precision(.fractionLength(3)))
                        if let ma20 = average(20).last?.value { LabeledContent("MA20", value: ma20, format: .number.precision(.fractionLength(3))) }
                        if let ma60 = average(60).last?.value { LabeledContent("MA60", value: ma60, format: .number.precision(.fractionLength(3))) }
                        if let rsi14 { LabeledContent("RSI14", value: "\(rsi14, specifier: "%.1f")") }
                        if let macd {
                            LabeledContent("MACD", value: "\(macd.line, specifier: "%.4f")")
                            LabeledContent("信号线 / 柱", value: "\(macd.signal, specifier: "%.4f") / \(macd.histogram, specifier: "%.4f")")
                        }
                        if let percentile { LabeledContent("区间收盘分位", value: "\(percentile, specifier: "%.1f")%") }
                        if let drawdown { LabeledContent("区间最大回撤", value: "\(drawdown * 100, specifier: "%.1f")%") }
                    }
                }
                Section("日线规则提示") {
                    if ruleAlerts.isEmpty {
                        Label("所选区间内未触发内置规则", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        ForEach(ruleAlerts, id: \.self) { rule in
                            Label(rule, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    Text("规则检查 MA20 穿越、单日 ±5%、区间回撤 10%、量能 2 倍且单日波动 3%。仅检查当前加载的日线，不是实时监控，也不会自动发通知或预测涨跌。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("MA5 / MA20 历史策略回测") {
                    TextField("初始资金（元）", text: $backtestCapital).keyboardType(.decimalPad)
                    TextField("单边费率（%）", text: $backtestFeePercent).keyboardType(.decimalPad)
                    Button("回测当前所选区间") { runBacktest() }
                    if let result = backtestResult {
                        LabeledContent("回测区间", value: "\(result.startDate) 至 \(result.endDate)")
                        LabeledContent("MA 策略期末资产", value: result.strategyValue, format: .currency(code: "CNY"))
                        LabeledContent("MA 策略收益", value: result.strategyReturn, format: .percent.precision(.fractionLength(2)))
                        LabeledContent("买入持有期末资产", value: result.holdValue, format: .currency(code: "CNY"))
                        LabeledContent("买入持有收益", value: result.holdReturn, format: .percent.precision(.fractionLength(2)))
                        LabeledContent("MA 策略最大回撤", value: result.maxDrawdown, format: .percent.precision(.fractionLength(2)))
                        LabeledContent("模拟委托次数", value: "\(result.orders)")
                    }
                    if !backtestMessage.isEmpty { Text(backtestMessage).font(.footnote).foregroundStyle(.orange) }
                    Text("收盘信号在下一交易日开盘成交，按 100 份整手及单边费率估算；不含滑点、停牌、涨跌停、真实税费与交易限制。腾讯前复权数据可能调整；历史结果不代表未来收益，也不构成买卖建议。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("最近日线") {
                    ForEach(bars.suffix(20).reversed()) { bar in
                        HStack { Text(bar.date); Spacer(); Text("收 \(bar.close, specifier: "%.3f")"); Text("高低 \(bar.high, specifier: "%.3f") / \(bar.low, specifier: "%.3f")").foregroundStyle(.secondary) }.font(.caption)
                    }
                }
            }
            .navigationTitle("日K与指标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { if allBars.isEmpty { await load(force: false) } }
        }
    }

    @MainActor private func load(force: Bool) async {
        guard !isLoading else { return }
        isLoading = true; message = ""
        defer { isLoading = false }
        do { _ = try await store.fetchDailyBars(code: holding.code, count: 640, force: force); message = "已载入 \(store.dailyBars[holding.code]?.count ?? 0) 个交易日" }
        catch { message = "获取失败：\(error.localizedDescription)" }
    }

    private func runBacktest() {
        guard let capital = Double(backtestCapital), let feePercent = Double(backtestFeePercent),
              let result = StrategyBacktest.run(bars: bars, initialCash: capital, feeRate: feePercent / 100) else {
            backtestResult = nil
            backtestMessage = "当前日线不足或参数无效；至少需要 25 个交易日，费率需为 0%–2%。"
            return
        }
        backtestResult = result; backtestMessage = ""
    }
}
