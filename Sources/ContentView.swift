import SwiftUI
import Charts
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            DashboardView().tabItem { Label("自选", systemImage: "diamond") }
            HoldingsView(kind: .etf).tabItem { Label("持仓", systemImage: "list.bullet.rectangle") }
            AssetsView().tabItem { Label("资产", systemImage: "chart.pie") }
            HoldingsView(kind: .fund).tabItem { Label("基金", systemImage: "building.columns") }
            ToolsView().tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }
        }
        .onAppear { store.configureNASSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.configureNASSync() }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAdd = false
    @State private var showAlertEditor = false
    var body: some View {
        NavigationStack {
            List {
                Section("账户概览") {
                    LabeledContent("总资产", value: store.totalAsset, format: .currency(code: "CNY"))
                    LabeledContent("持仓浮盈", value: store.totalPnL, format: .currency(code: "CNY"))
                    LabeledContent("已实现盈亏", value: store.realizedPnL, format: .currency(code: "CNY"))
                }
                Section("行情状态") {
                    Label(store.sourceStatus, systemImage: "circle.fill").foregroundStyle(.secondary)
                    Button("刷新行情") { store.refreshQuotes() }
                }
                Section("自选") {
                    if store.data.quotes.isEmpty { Text("还没有自选标的").foregroundStyle(.secondary) }
                    ForEach(store.data.quotes) { q in
                        HStack {
                            Text(q.name); Spacer()
                            Text(q.price, format: .number.precision(.fractionLength(3)))
                            Text(q.changePct, format: .percent.precision(.fractionLength(2)))
                                .foregroundStyle(q.changePct >= 0 ? .red : .green)
                        }
                    }.onDelete { offsets in store.data.quotes.remove(atOffsets: offsets); store.save() }
                }
                Section("价格提醒（一次性）") {
                    if store.data.quoteAlerts.isEmpty { Text("暂无提醒。需要允许系统通知，并在行情刷新时触发。").foregroundStyle(.secondary) }
                    ForEach(store.data.quoteAlerts) { alert in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(alert.name) · \(alert.code)")
                                Text("\(alert.direction == .above ? "上穿" : "下穿") \(alert.target, format: .number.precision(.fractionLength(3))) · \(alert.enabled ? "等待触发" : "已触发")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !alert.enabled {
                                Button("重启") { store.reenableQuoteAlert(alert) }.font(.caption)
                            }
                        }
                    }.onDelete { offsets in
                        let rows = store.data.quoteAlerts
                        for index in offsets { store.removeQuoteAlert(rows[index]) }
                    }
                }
            }.navigationTitle("观盘 Pro")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("添加自选", systemImage: "plus") { showAdd = true }
                    Button("添加价格提醒", systemImage: "bell.badge") { showAlertEditor = true }
                } label: { Image(systemName: "plus") }
            } }
            .sheet(isPresented: $showAdd) { WatchEditor() }
            .sheet(isPresented: $showAlertEditor) { QuoteAlertEditor() }
            .task {
                while !Task.isCancelled {
                    let interval = store.data.quoteRefreshSeconds
                    if scenePhase == .active && interval > 0 { store.refreshQuotes() }
                    try? await Task.sleep(for: .seconds(interval > 0 ? interval : 60))
                }
            }
        }
    }
}

struct QuoteAlertEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var target = ""
    @State private var direction: QuoteAlert.Direction = .above
    @State private var error = ""
    private var instruments: [AlertInstrument] {
        let values = store.data.quotes.map { AlertInstrument(code: $0.code, name: $0.name) }
            + store.data.holdings.filter { $0.kind == .etf }.map { AlertInstrument(code: $0.code, name: $0.name) }
        return Array(Dictionary(values.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.code < $1.code }
    }
    var body: some View {
        NavigationStack {
            Form {
                if !instruments.isEmpty {
                    Picker("标的", selection: $code) {
                        ForEach(instruments) { item in Text("\(item.name) · \(item.code)").tag(item.code) }
                    }
                } else { TextField("证券/ETF代码", text: $code) }
                Picker("触发方向", selection: $direction) {
                    Text("上穿目标价").tag(QuoteAlert.Direction.above)
                    Text("下穿目标价").tag(QuoteAlert.Direction.below)
                }
                TextField("目标价格", text: $target).keyboardType(.decimalPad)
                Text("沪深交易时段刷新行情并触达目标后发送一次本地通知，随后自动停用。需要允许系统通知；应用关闭、休市或行情接口不可用时不会实时监控。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("价格提醒")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear { if code.isEmpty { code = instruments.first?.code ?? "" } }
        }
    }
    private func save() {
        guard let value = Double(target) else { error = "请输入有效目标价。"; return }
        let name = instruments.first { $0.code == code }?.name ?? code
        Task {
            do {
                // Alerts are one-shot. Do not save one that could silently disable
                // itself later when iOS has no permission to show its notification.
                let allowed = try await NativeNotifications.requestPermission()
                guard allowed else {
                    error = "系统通知未授权，提醒没有保存。请在 iPhone「设置 > 通知 > 观盘 Pro」开启通知后重试。"
                    return
                }
                try store.addQuoteAlert(code: code, name: name, target: value, direction: direction)
                dismiss()
            } catch { error = error.localizedDescription }
        }
    }
}

private struct AlertInstrument: Identifiable {
    var code: String
    var name: String
    var id: String { code }
}

struct WatchEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("证券/ETF代码", text: $code).keyboardType(.numberPad)
                TextField("名称（可留空）", text: $name)
                Text("添加后可点刷新获取腾讯行情；接口不可用时会显示错误，不会用旧价格冒充实时行情。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("添加自选")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("添加") { store.addWatch(code: code.trimmingCharacters(in: .whitespaces), name: name.trimmingCharacters(in: .whitespaces)); dismiss(); store.refreshQuotes() } }
                }
        }
    }
}

struct HoldingsView: View {
    @EnvironmentObject var store: PortfolioStore
    let kind: Holding.Kind
    @State private var showAdd = false
    @State private var editTarget: Holding?
    @State private var tradeTarget: Holding?
    @State private var fundHistoryTarget: Holding?
    @State private var backfillTarget: Holding?
    @State private var dcaTarget: Holding?
    @State private var dividendTarget: Holding?
    @State private var feePolicyTarget: Holding?
    @State private var marketChartTarget: Holding?
    @State private var showFundCalendar = false
    @State private var archivedFundTarget: ArchivedFundItem?
    private var holdings: [Holding] { store.data.holdings.filter { $0.kind == kind } }
    private var title: String { kind == .fund ? "场外基金" : "ETF / 证券持仓" }

    private func fundTransactionLabel(_ trade: FundTransaction) -> String {
        switch trade.side {
        case .buy: return trade.isBackfill ? "历史起点补录" : ((trade.isAutomaticDCA ?? false) ? "自动定投 · \(trade.name)" : "申购 · \(trade.name)")
        case .sell: return "赎回 · \(trade.name)"
        case .dividend: return trade.dividendMode == .reinvest ? "红利再投资 · \(trade.name)" : "现金分红 · \(trade.name)"
        }
    }

    private func dcaDescription(_ plan: FundDCAPlan) -> String {
        switch plan.frequency {
        case .daily: return "每个有净值记录的交易日"
        case .weekly:
            let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            return "每\(names.indices.contains(plan.weekday) ? names[plan.weekday] : "周一")"
        case .biweekly: return "每两周一次"
        case .monthly: return "每月\(plan.monthDay)日或其后首个有净值日"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if holdings.isEmpty {
                    ContentUnavailableView("暂无\(title)", systemImage: "tray", description: Text("点右上角添加持仓。"))
                }
                if kind == .fund {
                    Section("自动定投（本机记账）") {
                        let plans = store.data.fundDCAPlans
                        if plans.isEmpty { Text("暂无自动定投计划。请在基金持仓卡片里点“定投”。").foregroundStyle(.secondary) }
                        ForEach(plans) { plan in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(plan.name)
                                    Text("\(plan.enabled ? "运行中" : "已暂停") · \(plan.amount, format: .currency(code: "CNY")) · 费率 \((plan.feeRate ?? 0.0015) * 100, specifier: "%.2f")% · \(dcaDescription(plan)) · 已记 \(plan.processedDates.count) 期")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    Button(plan.enabled ? "暂停计划" : "恢复计划") { store.setDCAPlan(plan, enabled: !plan.enabled) }
                                    Button("删除计划", role: .destructive) { store.removeDCAPlan(plan) }
                                } label: { Image(systemName: "ellipsis.circle") }
                            }
                        }
                        Text("只在对应交易日的已公布净值可用后记入份额/成本，不下单、不扣程序现金。周/月计划遇休市会顺延到同周/当月首个可用净值日；iOS 后台不保证准时运行，打开应用或更新净值时会补处理历史净值覆盖的计划期次。投入金额计入快照收益调整。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !store.data.legacyDCAEvents.isEmpty {
                        Section("旧版定投期次档案") {
                            ForEach(store.data.legacyDCAEvents) { event in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(event.name) · \(event.code)")
                                    Text("\(event.dueDate) · \(event.amount, format: .currency(code: "CNY")) · \(event.status)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("网页端期次及迁移状态会保留；没有自动补记成交，避免与已有申购流水重复。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("已公布净值") {
                        Button {
                            store.refreshFundNAVs()
                        } label: {
                            Label(store.isRefreshingFunds ? "正在更新基金净值…" : "更新已公布净值", systemImage: "arrow.clockwise")
                        }.disabled(store.isRefreshingFunds)
                        Text(store.fundNAVStatus).font(.footnote).foregroundStyle(.secondary)
                        Text(store.fundDCAStatus).font(.footnote).foregroundStyle(.secondary)
                        Button("基金日收益日历") { showFundCalendar = true }
                        Text("来源：天天基金公开净值历史；展示已公布净值，不是盘中估值。接口可能受网络策略影响。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(holdings) { h in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(h.name).font(.headline); Spacer(); Text(h.marketValue, format: .currency(code: "CNY")).font(.headline) }
                        Text("\(h.code) · \(h.quantity, specifier: "%.4f") 份 · 成本 \(h.cost, specifier: kind == .fund ? "%.4f" : "%.3f") · 现价 \(h.current, specifier: kind == .fund ? "%.4f" : "%.3f")")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack { Text("成本额 \(h.quantity * h.cost, format: .currency(code: "CNY"))"); Spacer(); Text(h.pnl, format: .currency(code: "CNY")).foregroundStyle(h.pnl >= 0 ? .red : .green) }
                            .font(.subheadline)
                        if kind == .fund, let latest = store.data.fundNAVHistory.filter({ $0.code == h.code }).max(by: { $0.date < $1.date }) {
                            let previous = store.data.fundNAVHistory.filter { $0.code == h.code && $0.date < latest.date }.max(by: { $0.date < $1.date })
                            if let previous {
                                let change = (latest.nav - previous.nav) * h.quantity
                                Text("\(latest.date) 近一期净值变化 · 按当前份额折算 \(change, format: .currency(code: "CNY"))")
                                    .font(.caption).foregroundStyle(change >= 0 ? .red : .green)
                            } else {
                                Text("最新净值日期：\(latest.date)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("买入 / 卖出") { tradeTarget = h }
                            Spacer()
                            if kind == .fund {
                                if h.quantity > 0 && !store.data.fundTransactions.contains(where: { $0.code == h.code && $0.side == .buy }) {
                                    Button("补录起点") { backfillTarget = h }
                                }
                                Button("定投") { dcaTarget = h }
                                Button("分红") { dividendTarget = h }
                                Button("净值走势") { fundHistoryTarget = h }
                                Button("赎回费率") { feePolicyTarget = h }
                            } else {
                                Button("日K与指标") { marketChartTarget = h }
                            }
                            Button("编辑") { editTarget = h }
                        }.buttonStyle(.borderless).font(.subheadline)
                    }.padding(.vertical, 5)
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) { store.removeHolding(h) }
                        Button("编辑") { editTarget = h }.tint(.blue)
                    }
                }
                Section(kind == .fund ? "最近基金流水" : "最近交易流水") {
                    if kind == .fund {
                        let codes = Set(holdings.map(\.code))
                        let entries = store.data.fundTransactions.filter { codes.contains($0.code) }
                            .sorted { $0.requestDate > $1.requestDate }.prefix(10)
                        if entries.isEmpty { Text("暂无基金流水").foregroundStyle(.secondary) }
                        ForEach(Array(entries)) { trade in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(fundTransactionLabel(trade))
                                    Text("\(trade.effectiveDate) · \(trade.quantity, specifier: "%.4f") 份\(trade.status == .pending ? " · 待确认" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Text(trade.amount, format: .currency(code: "CNY"))
                            }
                        }
                    } else {
                        let entries = store.data.ledger.filter { e in
                            holdings.contains(where: { $0.code == e.code && (e.kind == nil || e.kind == $0.kind) })
                        }.suffix(10).reversed()
                        if entries.isEmpty { Text("暂无交易流水").foregroundStyle(.secondary) }
                        ForEach(Array(entries)) { e in
                            HStack {
                                Text(e.name); Spacer()
                                Text(e.side == .buy ? "买入" : "卖出")
                                Text(e.gross, format: .currency(code: "CNY"))
                            }.font(.caption)
                        }
                    }
                }
                if kind == .fund {
                    Section("已移出持仓 · 历史保留") {
                        let activeCodes = Set(holdings.map(\.code))
                        let archivedCodes = Set(store.data.fundTransactions.map(\.code)).subtracting(activeCodes).sorted()
                        if archivedCodes.isEmpty { Text("暂无已移出持仓的基金历史").foregroundStyle(.secondary) }
                        ForEach(archivedCodes, id: \.self) { code in
                            let trades = store.data.fundTransactions.filter { $0.code == code }
                            let name = trades.first(where: { !$0.name.isEmpty })?.name ?? code
                            let realized = store.data.ledger.filter { $0.code == code && $0.kind == .fund }.reduce(0) { $0 + $1.realizedPnL }
                                + trades.filter { $0.side == .dividend && $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
                            Button { archivedFundTarget = ArchivedFundItem(code: code, name: name) } label: {
                                HStack {
                                    VStack(alignment: .leading) { Text(name); Text("\(trades.count) 笔流水 · 历史保留").font(.caption).foregroundStyle(.secondary) }
                                    Spacer(); Text(realized, format: .currency(code: "CNY"))
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if kind == .fund {
                        Button { store.refreshFundNAVs() } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(store.isRefreshingFunds)
                    }
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { HoldingEditor(kind: kind) }
            .sheet(item: $editTarget) { HoldingEditor(kind: kind, initial: $0) }
            .sheet(item: $tradeTarget) { TradeEditor(holding: $0) }
            .sheet(item: $fundHistoryTarget) { FundNAVHistoryView(fund: $0) }
            .sheet(item: $backfillTarget) { FundBackfillView(fund: $0) }
            .sheet(item: $dcaTarget) { FundDCAPlanEditor(holding: $0) }
            .sheet(item: $dividendTarget) { FundDividendEditor(holding: $0) }
            .sheet(item: $feePolicyTarget) { FundFeePolicyEditor(fund: $0) }
            .sheet(item: $marketChartTarget) { MarketChartView(holding: $0) }
            .sheet(isPresented: $showFundCalendar) { FundIncomeCalendarView() }
            .sheet(item: $archivedFundTarget) { ArchivedFundHistoryView(item: $0) }
        }
    }
}

struct ArchivedFundItem: Identifiable {
    var id: String { code }
    var code: String
    var name: String
}

struct TradeCSVImportView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var drafts: [TradeImportDraft] = []
    @State private var message = ""
    @State private var showImporter = false
    @State private var isImporting = false
    private var validSelected: Int { drafts.filter { $0.selected && $0.isValid }.count }
    private var invalidCount: Int { drafts.filter { !$0.isValid }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section("选择数据") {
                    Button("从文件选择 CSV / 表格") { showImporter = true }
                    TextEditor(text: $text).frame(minHeight: 110)
                    Button("识别并预览") { drafts = TradeCSVParser.parse(text); message = "识别到 \(drafts.count) 行，其中 \(drafts.filter(\.isValid).count) 行可导入。" }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("需要列名：日期、代码、买卖方向、价格、数量；手续费可选。支持逗号 CSV 和制表符表格。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !drafts.isEmpty {
                    Section("预览 · 可导入 \(validSelected) 行 · 未识别 \(invalidCount) 行") {
                        ForEach($drafts) { $draft in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(isOn: $draft.selected) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("第 \(draft.rowNumber) 行 · \(draft.name) · \(draft.code)")
                                        if let date = draft.date {
                                            Text("\(date.formatted(date: .numeric, time: .omitted)) · \(draft.side == .buy ? "买入" : "卖出") · \(draft.quantity, specifier: "%.4f") × \(draft.price, specifier: "%.4f") · 费 \(draft.fee, specifier: "%.2f")")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.disabled(!draft.isValid)
                                if let error = draft.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            }.padding(.vertical, 3)
                        }
                        Text("导入后只写历史流水，不变更当前份额和参考现金。卖出盈亏按完整买入历史的加权成本计算；若记录缺少更早买入、卖出超出累计买入，会拒绝整批导入。相同日期、代码、方向、数量和价格的已有流水会跳过。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button { importSelected() } label: {
                        Label(isImporting ? "正在导入…" : "确认导入所选 \(validSelected) 行", systemImage: "square.and.arrow.down")
                    }.disabled(validSelected == 0 || isImporting)
                }
                if !message.isEmpty { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle("导入成交历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try Data(contentsOf: url)
                    guard let content = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .unicode) else {
                        message = "文件编码无法识别，请另存为 UTF-8 CSV。"; return
                    }
                    text = content; drafts = TradeCSVParser.parse(content)
                    message = "已读取并识别 \(drafts.count) 行，请先核对预览。"
                } catch { message = "读取失败：\(error.localizedDescription)" }
            }
        }
    }

    private func importSelected() {
        isImporting = true
        defer { isImporting = false }
        do {
            let count = try store.importTradeLedger(drafts)
            message = count == 0 ? "所选流水均已存在，没有重复写入。" : "已导入 \(count) 笔历史成交流水；当前持仓和现金未改动。"
            drafts.removeAll()
        } catch { message = error.localizedDescription }
    }
}

struct ArchivedFundHistoryView: View {
    @EnvironmentObject var store: PortfolioStore
    let item: ArchivedFundItem

    private var transactions: [FundTransaction] {
        store.data.fundTransactions.filter { $0.code == item.code }.sorted { $0.effectiveDate > $1.effectiveDate }
    }
    private var points: [FundNAVPoint] {
        store.data.fundNAVHistory.filter { $0.code == item.code }.sorted { $0.date < $1.date }
    }
    private var realized: Double {
        store.data.ledger.filter { $0.code == item.code && $0.kind == .fund }.reduce(0) { $0 + $1.realizedPnL }
            + transactions.filter { $0.side == .dividend && $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("收益保留") {
                    LabeledContent("已实现盈亏", value: realized, format: .currency(code: "CNY"))
                    Text("移出持仓只隐藏当前持仓，不删除流水和净值历史。基金收益日历仍可使用这些记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if points.count > 1 {
                    Section("已公布净值走势") {
                        Chart(Array(points.suffix(300))) { point in
                            LineMark(x: .value("日期", point.date), y: .value("净值", point.nav))
                        }.frame(height: 210)
                    }
                }
                Section("基金流水") {
                    if transactions.isEmpty { Text("暂无流水").foregroundStyle(.secondary) }
                    ForEach(transactions) { trade in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(transactionTitle(trade)).font(.headline)
                                Spacer(); Text(trade.status == .pending ? "待确认" : "已确认")
                                    .foregroundStyle(trade.status == .pending ? .orange : .secondary)
                            }
                            Text("生效日 \(trade.effectiveDate) · \(trade.quantity, specifier: "%.4f") 份 · 净值 \(trade.nav, specifier: "%.4f")")
                                .font(.caption).foregroundStyle(.secondary)
                            if trade.fee > 0 { Text("费用 \(trade.fee, format: .currency(code: "CNY"))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func transactionTitle(_ trade: FundTransaction) -> String {
        switch trade.side {
        case .buy: return trade.isBackfill ? "历史起点补录" : "申购"
        case .sell: return "赎回"
        case .dividend: return trade.dividendMode == .reinvest ? "红利再投资" : "现金分红"
        }
    }
}

struct FundBackfillView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let fund: Holding
    @State private var date = Date.now
    @State private var quantity = ""
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("历史持有起始日", selection: $date, in: ...Date.now, displayedComponents: .date)
                TextField("当时总份额", text: $quantity).keyboardType(.decimalPad)
                Text("按现有份额和已记赎回流水，系统估算的起始份额为 \(store.inferredBackfillShares(for: fund), specifier: "%.4f")。补录只建立收益日历的份额基准，不改当前持仓、不新增交易或现金。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .navigationTitle("补录基金历史起点")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear {
                if quantity.isEmpty { quantity = String(store.inferredBackfillShares(for: fund)) }
            }
        }
    }
    private func save() {
        guard let value = Double(quantity), value.isFinite else { message = "请填写有效份额"; return }
        do { try store.recordFundBackfill(code: fund.code, date: date, quantity: value); dismiss() }
        catch { message = error.localizedDescription }
    }
}

struct FundDCAPlanEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var amount = "100"
    @State private var feeRatePercent = "0.15"
    @State private var frequency: FundDCAPlan.Frequency = .daily
    @State private var weekday = 2
    @State private var monthDay = 1
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("基金", value: "\(holding.name) · \(holding.code)")
                TextField("每期计划金额（元）", text: $amount).keyboardType(.decimalPad)
                TextField("申购费率（%）", text: $feeRatePercent).keyboardType(.decimalPad)
                Picker("频率", selection: $frequency) {
                    Text("每个净值交易日").tag(FundDCAPlan.Frequency.daily)
                    Text("每周指定交易日").tag(FundDCAPlan.Frequency.weekly)
                    Text("每两周一次").tag(FundDCAPlan.Frequency.biweekly)
                    Text("每月指定日期").tag(FundDCAPlan.Frequency.monthly)
                }
                if frequency == .weekly {
                    Picker("星期", selection: $weekday) {
                        Text("周一").tag(2); Text("周二").tag(3); Text("周三").tag(4)
                        Text("周四").tag(5); Text("周五").tag(6)
                    }
                }
                if frequency == .monthly {
                    Stepper("每月第 \(monthDay) 日", value: $monthDay, in: 1...28)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Text("这是本机定投计划记账，不连接券商、不下单，也不改变参考现金。份额按（计划金额 − 申购费）÷ 对应日已公布净值计算，计划金额计入基金成本。默认申购费率 0.15%，请按基金实际费率修改。每周/每月休市时顺延到同周/当月首个可用净值日；没有对应净值时不猜价、不补成交。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("设置自动定投")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("启用") {
                        guard let value = Double(amount), value.isFinite, value > 0,
                              let rate = Double(feeRatePercent), rate.isFinite, (0...5).contains(rate) else {
                            error = "请输入有效金额和 0～5% 的申购费率"; return
                        }
                        do {
                            try store.addDCAPlan(code: holding.code, name: holding.name, amount: value, feeRatePercent: rate,
                                frequency: frequency, weekday: weekday, monthDay: monthDay)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

private struct FeeBandDraft: Identifiable {
    var id = UUID()
    var days: String
    var rate: String
}

struct FundFeePolicyEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let fund: Holding
    @State private var bands = [0, 7, 30, 365, 730].map { FeeBandDraft(days: String($0), rate: "") }
    @State private var sellMode: FundSellMode = .fifo
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("按基金合同配置赎回费") {
                    Picker("赎回批次策略", selection: $sellMode) {
                        ForEach(FundSellMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Text("低费率策略会优先使用当前持有天数对应费率较低的批次；同费率时先使用较早批次。策略只用于估费和本地记录，实际扣费与销售平台批次以平台确认为准。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach($bands) { $band in
                        HStack {
                            TextField("持有天数起点", text: $band.days).keyboardType(.numberPad)
                            Text("天起")
                            TextField("费率 %", text: $band.rate).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .onDelete { bands.remove(atOffsets: $0) }
                    Button("增加一个费率档") {
                        let next = (bands.compactMap { Int($0.days) }.max() ?? 0) + 30
                        bands.append(FeeBandDraft(days: String(next), rate: ""))
                    }
                    Text("至少需要 0 天起始档；程序按所选赎回批次逐笔计算持有天数，并套用最近的费率档。请按该基金销售页面/合同填写，缺失费率或买入批次不完整时不会估算，不会擅自认定为 0 费率。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .navigationTitle("\(fund.name)赎回费率")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear {
                if let policy = store.data.fundFeePolicies.first(where: { $0.code == fund.code }) {
                    bands = policy.bands.map { FeeBandDraft(days: String($0.minimumHoldingDays), rate: String($0.ratePercent)) }
                    sellMode = policy.sellMode ?? .fifo
                }
            }
        }
    }

    private func save() {
        let parsed = bands.compactMap { row -> FundFeeBand? in
            guard let days = Int(row.days), let rate = Double(row.rate) else { return nil }
            return FundFeeBand(minimumHoldingDays: days, ratePercent: rate)
        }
        guard parsed.count == bands.count else { message = "每个档位都要填写持有天数和费率。"; return }
        do { try store.saveFundFeePolicy(code: fund.code, name: fund.name, bands: parsed, sellMode: sellMode); dismiss() }
        catch { message = error.localizedDescription }
    }
}

struct FundDividendEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var amount = ""
    @State private var nav = ""
    @State private var date = Date.now
    @State private var mode: FundTransaction.DividendMode = .cash
    @State private var linkCash = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("基金", value: "\(holding.name) · \(holding.code)")
                DatePicker("分红到账/确认日", selection: $date, displayedComponents: .date)
                TextField("分红金额", text: $amount).keyboardType(.decimalPad)
                Picker("分红方式", selection: $mode) {
                    Text("现金分红").tag(FundTransaction.DividendMode.cash)
                    Text("红利再投资").tag(FundTransaction.DividendMode.reinvest)
                }.pickerStyle(.segmented)
                if mode == .reinvest {
                    TextField("再投资净值", text: $nav).keyboardType(.decimalPad)
                    if let cash = Double(amount), let value = Double(nav), value > 0, cash > 0 {
                        LabeledContent("增加份额", value: cash / value, format: .number.precision(.fractionLength(4)))
                    }
                } else {
                    Toggle("计入本程序参考现金", isOn: $linkCash)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Text("分红会计入累计收益。红利再投资按填写净值增加基金份额和成本；现金分红默认不改参考现金，只有确认资金也记在本程序现金中时才打开上面的开关。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("记录基金分红")
            .onAppear { nav = nav.isEmpty ? String(holding.current) : nav }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let cash = Double(amount), cash.isFinite, cash > 0 else { error = "请输入有效分红金额"; return }
                        let effectiveNAV = Double(nav) ?? 0
                        do {
                            try store.recordFundDividend(code: holding.code, date: date, amount: cash,
                                mode: mode, nav: effectiveNAV, linkCash: mode == .cash && linkCash)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

struct FundIncomeCalendarView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var monthOffset = 0

    private var monthDate: Date { Calendar(identifier: .gregorian).date(byAdding: .month, value: monthOffset, to: .now) ?? .now }
    private var monthKey: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: monthDate)
    }
    private var days: [FundDailyPerformance] { store.fundDailyPerformance(month: monthKey) }
    private var total: Double { days.reduce(0) { $0 + $1.profit } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                        Spacer(); Text(monthKey).font(.headline)
                        Spacer(); Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                    }
                    LabeledContent("本月已记录日收益合计", value: total, format: .currency(code: "CNY"))
                    Text("共 \(days.count) 个有数据的净值日。这里只展示已公布净值覆盖且有已确认申购/补录份额依据的基金。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("每日收益") {
                    if days.isEmpty {
                        ContentUnavailableView("暂无可核算收益", systemImage: "calendar", description: Text("需要先导入基金买卖流水，并获取覆盖对应日期的已公布净值历史。手动录入但没有买入日期的持仓不会被猜测成历史收益。"))
                    }
                    ForEach(days.reversed()) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(day.date); Spacer(); Text(day.profit, format: .currency(code: "CNY")) }
                                .foregroundStyle(day.profit >= 0 ? .red : .green)
                            Text("净值基数 \(day.baseValue, format: .currency(code: "CNY")) · \(day.fundCount) 只基金")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("日收益按前一净值日已确认份额计算；当日买入不计入当日净值变化，当日赎回份额仍计入；分红金额和申赎费用按流水日计入。手动持仓若缺少历史买入流水，会被排除，因此历史可能不完整。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("基金收益日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

struct FundNAVHistoryView: View {
    @EnvironmentObject var store: PortfolioStore
    let fund: Holding

    private var points: [FundNAVPoint] {
        store.data.fundNAVHistory.filter { $0.code == fund.code }.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("已公布净值，不是盘中估值") {
                    if let latest = points.last {
                        LabeledContent("最新净值日期", value: latest.date)
                        LabeledContent("最新净值", value: latest.nav, format: .number.precision(.fractionLength(4)))
                        if points.count > 1, let previous = points.dropLast().last {
                            let navChange = latest.nav - previous.nav
                            LabeledContent("较上一期", value: navChange, format: .number.precision(.fractionLength(4)))
                            LabeledContent("按当前份额折算", value: navChange * fund.quantity, format: .currency(code: "CNY"))
                        }
                    } else {
                        ContentUnavailableView("暂无净值历史", systemImage: "chart.xyaxis.line", description: Text("回到基金页点击“更新已公布净值”。"))
                    }
                }
                if points.count > 1 {
                    Section("历史净值") {
                        Chart(Array(points.suffix(300))) { point in
                            LineMark(x: .value("日期", point.date), y: .value("单位净值", point.nav))
                                .interpolationMethod(.catmullRom)
                        }
                        .frame(height: 230)
                        .accessibilityLabel("\(fund.name)历史单位净值曲线")
                    }
                    Section("最近净值") {
                        ForEach(points.suffix(20).reversed()) { point in
                            HStack { Text(point.date); Spacer(); Text(point.nav, format: .number.precision(.fractionLength(4))) }
                        }
                    }
                }
                Text("历史净值变化只反映单位净值变化；“按当前份额折算”没有还原过去每天的实际份额，不能当作历史账户收益。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle(fund.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct HoldingEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let kind: Holding.Kind
    var initial: Holding?
    @State private var code: String
    @State private var name: String
    @State private var quantity: String
    @State private var cost: String
    @State private var current: String
    @State private var lookupMessage = ""

    init(kind: Holding.Kind, initial: Holding? = nil) {
        self.kind = kind; self.initial = initial
        _code = State(initialValue: initial?.code ?? "")
        _name = State(initialValue: initial?.name ?? "")
        _quantity = State(initialValue: initial.map { String($0.quantity) } ?? "")
        _cost = State(initialValue: initial.map { String($0.cost) } ?? "")
        _current = State(initialValue: initial.map { String($0.current) } ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("标的信息") {
                    TextField("代码", text: $code).keyboardType(.numberPad)
                    TextField("名称", text: $name)
                    if kind == .etf && !lookupMessage.isEmpty {
                        Text(lookupMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("份额和价格") {
                    TextField("份额", text: $quantity).keyboardType(.decimalPad)
                    TextField("成本净值/成本价", text: $cost).keyboardType(.decimalPad)
                    TextField("当前净值/价格", text: $current).keyboardType(.decimalPad)
                }
                Text(kind == .etf
                    ? "这里只维护本机持仓，不连接券商或执行交易。输入六位代码后会尝试识别名称和现价；行情接口不可用时可手动填写。"
                    : "这里只维护本机基金持仓，不连接销售平台或执行申赎。净值以最近已公布数据为准，可在基金页刷新。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .onChange(of: code) { oldValue, newValue in
                if oldValue != newValue, let initial, initial.code != newValue {
                    name = ""
                    current = ""
                }
                if oldValue != newValue { lookupMessage = "" }
            }
            .task(id: code) {
                let requested = code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard kind == .etf, requested.count == 6, requested.allSatisfy(\.isNumber),
                      initial?.code != requested else { return }
                lookupMessage = "正在识别代码…"
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                do {
                    guard let quote = try await store.lookupETFQuote(code: requested), !Task.isCancelled,
                          code.trimmingCharacters(in: .whitespacesAndNewlines) == requested else {
                        if !Task.isCancelled { lookupMessage = "未识别到该代码，可手动填写名称和现价。" }
                        return
                    }
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = quote.name }
                    if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == "0" { current = String(quote.price) }
                    lookupMessage = "已识别：\(quote.name) · 现价\(quote.price)"
                } catch {
                    if !Task.isCancelled { lookupMessage = "行情接口暂不可用，可手动填写名称和现价。" }
                }
            }
            .navigationTitle(initial == nil ? "添加持仓" : "编辑持仓")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
    }
    private func save() {
        let cde = code.trimmingCharacters(in: .whitespaces)
        guard !cde.isEmpty, let q = Double(quantity), q >= 0, q.isFinite,
              let c = Double(cost), c >= 0, c.isFinite,
              let p = Double(current), p >= 0, p.isFinite else { return }
        let h = Holding(code: cde, name: name.isEmpty ? cde : name, quantity: q, cost: c, current: p, kind: kind)
        store.upsertHolding(h, oldCode: initial?.code); dismiss()
    }
}

struct TradeEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var side: LedgerEntry.Side = .buy
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = "0"
    @State private var linkCash = false
    @State private var tradeDate = Date.now
    @State private var settlementDate = Date.now
    @State private var error = ""
    @State private var feeEstimateText = ""
    @State private var estimatedRedemptionLots: [FundLotRedemption]?
    @State private var estimatedQuantity = ""
    @State private var estimatedTradeDay = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(holding.name) {
                    Picker("方向", selection: $side) { Text("买入").tag(LedgerEntry.Side.buy); Text("卖出").tag(LedgerEntry.Side.sell) }.pickerStyle(.segmented)
                    TextField("份额", text: $quantity).keyboardType(.decimalPad)
                    TextField("成交价/净值", text: $price).keyboardType(.decimalPad)
                    TextField("手续费", text: $fee).keyboardType(.decimalPad)
                    if holding.kind == .fund {
                        if side == .sell {
                            Button("按所选批次策略估算赎回费") { estimateFundFee() }
                            if !feeEstimateText.isEmpty { Text(feeEstimateText).font(.footnote).foregroundStyle(.secondary) }
                        }
                        DatePicker("申请日期", selection: $tradeDate, displayedComponents: .date)
                        DatePicker("确认/净值生效日", selection: $settlementDate, displayedComponents: .date)
                    } else {
                        DatePicker("成交日期", selection: $tradeDate, displayedComponents: .date)
                    }
                    if holding.kind == .etf { Toggle("联动本程序现金", isOn: $linkCash) }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Text(holding.kind == .etf ? "ETF 手续费默认按每笔 0.10 元填写，可按券商实收修改；卖出盈亏按当前成本价计算。是否联动参考现金逐笔选择。" : "基金申赎费优先以实际扣费为准。可按基金合同配置费率与赎回批次策略；估算不等于销售平台最终扣费，交易不会连接销售平台。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("记一笔交易")
            .onChange(of: quantity) { _, _ in clearFundFeeEstimate() }
            .onChange(of: tradeDate) { _, _ in clearFundFeeEstimate() }
            .onChange(of: side) { _, _ in clearFundFeeEstimate() }
            .onAppear {
                linkCash = holding.kind == .etf && store.data.cashLinkedByDefault
                fee = holding.kind == .etf ? "0.10" : "0"
                settlementDate = tradeDate
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("入账") { save() } }
            }
        }
    }
    private func save() {
        guard let q = Double(quantity), let p = Double(price), let f = Double(fee) else { error = "请输入有效数字"; return }
        do { try store.recordTrade(code: holding.code, kind: holding.kind, side: side, quantity: q, price: p,
            fee: f, linkedCash: linkCash, date: tradeDate,
            settlementDate: holding.kind == .fund ? settlementDate : nil,
            fundRedemptionLots: estimatedQuantity == quantity && estimatedTradeDay == dayKey(tradeDate) ? estimatedRedemptionLots : nil); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func estimateFundFee() {
        guard let shares = Double(quantity), let nav = Double(price), shares > 0, nav > 0 else {
            feeEstimateText = "先填写有效赎回份额和净值。"; return
        }
        guard let estimate = store.estimateFundRedemptionFee(code: holding.code, shares: shares, nav: nav, on: tradeDate) else {
            feeEstimateText = "无法可靠估算：请先录入完整持有批次，并按基金合同设置全部适用费率档。"; return
        }
        fee = String(format: "%.2f", estimate.total)
        estimatedRedemptionLots = estimate.redemptionLots
        estimatedQuantity = quantity
        estimatedTradeDay = dayKey(tradeDate)
        let detail = estimate.parts.map { String(format: "%@买入 · %d天 %.2f份 × %.3f%%", $0.purchaseDate, $0.days, $0.shares, $0.ratePercent) }.joined(separator: "；")
        feeEstimateText = "批次估算 \(estimate.total, format: .currency(code: "CNY"))：\(detail)。请与实际扣费核对后再入账。"
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func clearFundFeeEstimate() {
        estimatedRedemptionLots = nil
        estimatedQuantity = ""
        estimatedTradeDay = ""
    }
}

struct AssetsView: View {
    @EnvironmentObject var store: PortfolioStore
    @State private var showCashFlow = false
    @State private var selectedSnapshotMonth = ""
    @State private var selectedLedgerMonth = ""
    var body: some View {
        NavigationStack {
            List {
                Section("账户总览") {
                    LabeledContent("总资产", value: store.totalAsset, format: .currency(code: "CNY"))
                    LabeledContent("证券/基金市值", value: store.totalMarketValue, format: .currency(code: "CNY"))
                    LabeledContent("参考现金", value: store.data.cash, format: .currency(code: "CNY"))
                    LabeledContent("持仓浮动盈亏", value: store.totalPnL, format: .currency(code: "CNY"))
                    LabeledContent("已实现盈亏", value: store.realizedPnL, format: .currency(code: "CNY"))
                    Button("记录现金转入 / 转出") { showCashFlow = true }
                }
                Section("历史快照") {
                    Button("记录/更新今日快照") { store.recordSnapshot() }
                    Text("快照之间的收益 = 总资产变化 − 期间现金净转入。没有快照覆盖的日期无法回溯；基金净值尚未更新时快照也会沿用当前账面值。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !store.snapshotMonths.isEmpty {
                        Picker("月份", selection: $selectedSnapshotMonth) {
                            ForEach(store.snapshotMonths, id: \.self) { Text($0).tag($0) }
                        }
                        if let summary = store.snapshotMonthSummary(selectedSnapshotMonth) {
                            LabeledContent("区间收益（扣除净转入）", value: summary.pnl, format: .currency(code: "CNY"))
                            Text("实测区间：\(summary.start.date) → \(summary.end.date)。\(summary.complete ? "有月初前基准快照；数值截至所选月最后一条快照，不代表缺失日期的逐日收益。" : "缺少月初前基准快照，当前从本月首条快照起算，不能代表完整月收益。")")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("该月快照不足两条，无法计算区间收益。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if store.data.snapshots.isEmpty { Text("暂无快照").foregroundStyle(.secondary) }
                    let sortedSnapshots = store.data.snapshots.sorted { $0.date < $1.date }
                    if sortedSnapshots.count > 1 {
                        Chart(Array(sortedSnapshots.suffix(60))) { s in
                            LineMark(x: .value("日期", s.date), y: .value("总资产", s.total))
                                .interpolationMethod(.catmullRom)
                        }.frame(height: 190).accessibilityLabel("最近60条总资产快照曲线")
                    }
                    ForEach(Array(sortedSnapshots.indices.reversed()), id: \.self) { index in
                        let s = sortedSnapshots[index]
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(s.date); Spacer(); Text(s.total, format: .currency(code: "CNY")) }
                            if index > 0 {
                                let prior = sortedSnapshots[index - 1]
                                let result = store.snapshotReturn(from: prior, to: s)
                                Text("较上次快照收益（已扣除现金流） \(result, format: .currency(code: "CNY"))")
                                    .font(.caption).foregroundStyle(result >= 0 ? .red : .green)
                            }
                        }
                    }
                }
                Section("ETF / 证券已实现收益") {
                    if store.ledgerMonths.isEmpty {
                        Text("暂无带类别标记的 ETF / 证券卖出流水。历史未标记流水不会被猜测归类。")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("流水月份", selection: $selectedLedgerMonth) {
                            ForEach(store.ledgerMonths, id: \.self) { Text($0).tag($0) }
                        }
                        let daily = store.ledgerDailyRealized(month: selectedLedgerMonth)
                        LabeledContent("本月已实现盈亏", value: daily.reduce(0) { $0 + $1.profit }, format: .currency(code: "CNY"))
                        if daily.isEmpty {
                            Text("本月没有已记录的 ETF / 证券卖出流水。买入和持仓浮盈不包含在这里。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(daily.enumerated()), id: \.offset) { item in
                                let day = item.element
                                HStack {
                                    Text(day.date)
                                    Text("\(day.trades) 笔流水").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(day.profit, format: .currency(code: "CNY"))
                                        .foregroundStyle(day.profit >= 0 ? .red : .green)
                                }
                            }
                        }
                        Text("这里只统计卖出落袋盈亏；没有每日历史行情/快照时，不能还原历史持仓浮盈或完整账户每日收益。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("近期现金流") {
                    if store.data.cashFlows.isEmpty { Text("暂无转入或转出记录").foregroundStyle(.secondary) }
                    ForEach(store.data.cashFlows.sorted { $0.date > $1.date }.prefix(10)) { flow in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(flow.memo.isEmpty ? (flow.amount > 0 ? "现金转入" : "现金转出") : flow.memo)
                                Text(flow.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(flow.amount, format: .currency(code: "CNY"))
                                .foregroundStyle(flow.amount >= 0 ? .red : .green)
                        }
                    }
                }
            }.navigationTitle("资产")
                .onAppear {
                    if selectedSnapshotMonth.isEmpty { selectedSnapshotMonth = store.snapshotMonths.first ?? "" }
                    if selectedLedgerMonth.isEmpty { selectedLedgerMonth = store.ledgerMonths.first ?? "" }
                }
                .sheet(isPresented: $showCashFlow) { CashFlowEditor() }
        }
    }
}

struct CashFlowEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var isDeposit = true
    @State private var amount = ""
    @State private var memo = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("方向", selection: $isDeposit) {
                    Text("转入").tag(true); Text("转出").tag(false)
                }.pickerStyle(.segmented)
                TextField("金额", text: $amount).keyboardType(.decimalPad)
                TextField("备注（可选）", text: $memo)
                LabeledContent("当前参考现金", value: store.data.cash, format: .currency(code: "CNY"))
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Text("这里只记录账户外部转入/转出，用于从快照变化中剔除入金影响；不会连接券商。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("现金流记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
    }
    private func save() {
        guard let value = Double(amount), value.isFinite, value > 0 else { error = "请输入大于 0 的有效金额"; return }
        do { try store.adjustCash(amount: isDeposit ? value : -value, memo: memo); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct ToolsView: View {
    @EnvironmentObject var store: PortfolioStore
    @State private var shockPercent = 20
    @State private var showGrid = false
    @State private var showAIAnalysis = false
    @State private var showLedgerHealth = false
    @State private var showTradePlans = false
    @State private var showOverlap = false
    @State private var showAddCash = false
    @State private var showFundReplay = false
    @State private var showTradeCSVImport = false
    @State private var targetEdit: Holding?
    var body: some View {
        NavigationStack { List {
            Section("账户压力测试") {
                Picker("统一下跌情景", selection: $shockPercent) {
                    Text("−10%").tag(10); Text("−20%").tag(20); Text("−30%").tag(30); Text("−50%").tag(50)
                }.pickerStyle(.segmented)
                let loss = store.data.holdings.reduce(0.0) { $0 + max(0, $1.marketValue) * Double(shockPercent) / 100 }
                LabeledContent("假设持仓损失", value: loss, format: .currency(code: "CNY"))
                LabeledContent("假设压力后总资产", value: max(0, store.totalAsset - loss), format: .currency(code: "CNY"))
                ForEach(Array(store.data.holdings.enumerated()), id: \.offset) { item in
                    let holding = item.element
                    let itemLoss = max(0, holding.marketValue) * Double(shockPercent) / 100
                    HStack {
                        Text(holding.name)
                        Spacer()
                        Text("−\(itemLoss, format: .currency(code: "CNY"))").foregroundStyle(.green)
                    }
                }
                Text("统一冲击全部当前持仓，现金不变；这是静态压力情景，不是行情预测，不包含相关性、流动性、费用或基金估值滞后。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("定投资金安排") {
                LabeledContent("未来 30 天计划投入", value: store.plannedDCAAmount(next: 30), format: .currency(code: "CNY"))
                LabeledContent("未来 90 天计划投入", value: store.plannedDCAAmount(next: 90), format: .currency(code: "CNY"))
                Text("按当前启用的定投计划和工作日估算，不检查银行卡/销售平台余额，也不扣本程序参考现金；节假日由实际净值确认后处理。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("目标仓位与再平衡参考") {
                let configured = store.data.allocationTargets.reduce(0) { $0 + $1.targetPercent }
                LabeledContent("已配置目标合计", value: configured / 100, format: .percent.precision(.fractionLength(1)))
                LabeledContent("未分配目标比例", value: max(0, 100 - configured) / 100, format: .percent.precision(.fractionLength(1)))
                ForEach(store.data.holdings) { holding in
                    let target = store.data.allocationTargets.first { $0.code == holding.code && $0.kind == holding.kind }
                    let targetPercent = target?.targetPercent ?? 0
                    let difference = store.totalAsset * targetPercent / 100 - holding.marketValue
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(holding.name).font(.headline); Spacer(); Button(target == nil ? "设目标" : "修改") { targetEdit = holding } }
                        Text("当前 \(store.allocationActualPercent(for: holding), specifier: "%.1f")% · 目标 \(targetPercent, specifier: "%.1f")%")
                            .font(.caption).foregroundStyle(.secondary)
                        if target != nil {
                            Text("偏差参考：\(difference >= 0 ? "需增加" : "可减少") \(abs(difference), format: .currency(code: "CNY"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("占比按总资产（含参考现金）计算。偏差只作为手动复核参考，不会自动买卖；场外基金采用最近已公布净值，净值滞后时偏差也会滞后。目标总和超过 100% 时请自行调整。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("日内网格与分时回放") {
                LabeledContent("本地分时记录", value: "\(store.gridBarCount) 点 · \(store.gridTradingDays.count) 个交易日")
                Button("网格计划、分时导入与复盘") { showGrid = true }
                Text("回放使用选定日期实际导入或前台采集的数据，结果是路径模拟，不是可实现收益保证。只在穿越网格价位时记模拟成交；不会修改主账户现金、持仓或流水。iOS 切后台可能暂停采集。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("AI 账户分析") {
                Button("配置接口并分析") { showAIAnalysis = true }
                Text("只在你点击分析时，将已保存的投资偏好、当前持仓、自选行情、现金和最近 20 条快照发送给你配置的模型接口。结果供研究参考，不会自动交易。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("本地数据检查") {
                Button("运行账本体检") { showLedgerHealth = true }
                Text("只读检查持仓、交易流水、基金、现金、快照和净值历史，不会自动修改账本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("券商成交历史导入") {
                Button("导入成交 CSV / 表格") { showTradeCSVImport = true }
                Text("先解析并预览，再由你确认入账。只增加 ETF/证券历史流水并计算可核实的已实现盈亏，不修改当前持仓或现金；需提供从首次买入开始的完整记录，避免把历史成交重复加到当前余额。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("交易计划与复盘") {
                Button("打开计划记录（\(store.data.tradePlans.count)）") { showTradePlans = true }
                Text("记录交易理由、计划价和失效条件；手动成交后可复盘执行偏差，不会自动下单或修改真实账本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("ETF 底层持仓穿透") {
                Button("查看成分股重叠") { showOverlap = true }
                Text("用旧版内置的 ETF 前十大成分股快照统计跨 ETF 重叠；数据截至 2026-06-30，场外基金和更深层成分不在本次统计。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("新增资金加仓试算") {
                Button("计算买入份额") { showAddCash = true }
                Text("按目标仓位缺口、整手和预算约束试算；不会下单或改动持仓。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("历史定投回放") {
                Button("按已公布基金净值回放") { showFundReplay = true }
                Text("只用已公布历史净值和用户选择的月投金额，不包含基金盘中估值；结果不代表未来表现。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("迁移进度") {
                Label("原生账本、交易流水、现金和快照", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("基金已公布净值历史与流水可核算的日收益", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("自动定投本地记账（不下单、可按净值历史补记）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("基金现金分红/红利再投资记账", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("基金自设赎回费率档与三种批次策略", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("价格上穿/下穿本地一次性提醒", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("ETF 行情及基金净值抓取待 iPhone 网络验证", systemImage: "clock").foregroundStyle(.secondary)
                Label("日内网格回放与永久分时历史存储", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("AI 外部模型分析（手动触发、API 密钥存于本机钥匙串）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("本地账本只读体检", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("旧版交易计划迁移与复盘", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("ETF 前十大成分重叠（快照截至 2026-06-30）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("券商 CSV 成交预览与流水导入（不改持仓/现金）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("ETF 目标仓位加仓试算", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("基金已公布净值历史定投回放", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("基金盘中估值（按要求不迁移）", systemImage: "minus.circle.fill").foregroundStyle(.secondary)
                Label("ETF 前复权日K、MA5/20/60、RSI14、MACD、分位与回撤", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("MA5/20 下一开盘信号回测与买入持有对照", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("日线 MA20 / 波动 / 回撤 / 量价规则检查", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("系统安排后台行情刷新尝试（iOS 不保证准时）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("NAS 网页/原生隔离同步、自动冲突检测与分时日线归档", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text("AI 分析只读取本机已记录的数据；缺少有效日线或资讯时，不会提供相应技术判断或新闻结论。")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("工具")
            .sheet(isPresented: $showGrid) { DayGridView() }
            .sheet(isPresented: $showAIAnalysis) { AIAnalysisView() }
            .sheet(isPresented: $showLedgerHealth) { LedgerHealthView() }
            .sheet(isPresented: $showTradePlans) { TradePlansView() }
            .sheet(isPresented: $showOverlap) { ETFOverlapView() }
            .sheet(isPresented: $showAddCash) { AddCashSimulationView() }
            .sheet(isPresented: $showFundReplay) { FundDCAReplayView() }
            .sheet(isPresented: $showTradeCSVImport) { TradeCSVImportView() }
            .sheet(item: $targetEdit) { holding in
                AllocationTargetEditor(holding: holding,
                    targetPercent: store.data.allocationTargets.first { $0.code == holding.code && $0.kind == holding.kind }?.targetPercent)
            }
        }
    }
}

struct LedgerHealthView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    private var findings: [LedgerHealthFinding] { store.ledgerHealthReport() }
    private var errors: Int { findings.filter { $0.severity.rawValue == LedgerHealthFinding.Severity.error.rawValue }.count }
    private var warnings: Int { findings.filter { $0.severity.rawValue == LedgerHealthFinding.Severity.warning.rawValue }.count }

    var body: some View {
        NavigationStack {
            List {
                Section("检查结果") {
                    LabeledContent("错误", value: "\(errors)")
                    LabeledContent("提醒", value: "\(warnings)")
                    Text("检查只读取本机数据。发现异常时，请先导出备份，再根据原始交易记录人工核对。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("详细项目") {
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: finding.severity))
                                    .foregroundStyle(color(for: finding.severity))
                                Text(finding.category).font(.caption).foregroundStyle(.secondary)
                                Text(finding.title).font(.subheadline.weight(.medium))
                            }
                            if !finding.detail.isEmpty {
                                Text(finding.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("账本体检")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func icon(for severity: LedgerHealthFinding.Severity) -> String {
        switch severity {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for severity: LedgerHealthFinding.Severity) -> Color {
        switch severity {
        case .normal: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct ConstituentExposure: Identifiable {
    var code: String
    var name: String
    var exposure: Double
    var sources: [(name: String, percent: Double)]
    var id: String { code }
}

struct ETFOverlapView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    private var etfs: [Holding] { store.data.holdings.filter { $0.kind == .etf } }
    private var covered: [(Holding, [ETFConstituent])] {
        etfs.compactMap { holding in
            guard let rows = ETFConstituentLibrary.holdings[holding.code] else { return nil }
            return (holding, rows)
        }
    }
    private var exposureRows: [ConstituentExposure] {
        var grouped: [String: (name: String, value: Double, sources: [(String, Double)])] = [:]
        for (holding, constituents) in covered {
            let marketValue = max(0, holding.marketValue)
            for item in constituents {
                let amount = marketValue * item.weightPercent / 100
                var row = grouped[item.code] ?? (item.name, 0, [])
                row.value += amount
                row.sources.append((holding.name, item.weightPercent))
                grouped[item.code] = row
            }
        }
        return grouped.map { code, row in
            ConstituentExposure(code: code, name: row.name, exposure: row.value,
                sources: row.sources.sorted { $0.1 > $1.1 }.map { (name: $0.0, percent: $0.1) })
        }.sorted { $0.exposure > $1.exposure }
    }
    private var duplicates: [ConstituentExposure] { exposureRows.filter { $0.sources.count > 1 } }
    private var coveredWeight: Double { covered.reduce(0) { $0 + $1.0.marketValue * $1.1.reduce(0) { $0 + $1.weightPercent } / 100 } }

    var body: some View {
        NavigationStack {
            List {
                Section("覆盖情况") {
                    LabeledContent("持有 ETF", value: "\(etfs.count) 只")
                    LabeledContent("有成分快照", value: "\(covered.count) 只")
                    LabeledContent("前十大对应市值", value: coveredWeight, format: .currency(code: "CNY"))
                    LabeledContent("重复成分敞口合计", value: duplicates.reduce(0) { $0 + $1.exposure }, format: .currency(code: "CNY"))
                    Text("快照日期：\(ETFConstituentLibrary.asOf)。成分权重仅限前十大，未覆盖部分不代表没有重复持仓。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !store.data.holdings.filter({ $0.kind == .fund }).isEmpty {
                    Section("场外基金") { Text("本地版暂未获取基金定期报告成分，未纳入重叠统计。")
                        .font(.footnote).foregroundStyle(.secondary) }
                }
                Section("跨 ETF 重复成分 · \(duplicates.count) 只") {
                    if duplicates.isEmpty { Text(covered.count < 2 ? "至少需要两只拥有内置成分快照的 ETF 才能比较。" : "前十大快照中未发现跨 ETF 重复成分。")
                        .foregroundStyle(.secondary) }
                    ForEach(duplicates) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(item.name).font(.headline); Spacer(); Text(item.exposure, format: .currency(code: "CNY")).font(.subheadline) }
                            Text("\(item.code) · 出现在 \(item.sources.count) 只 ETF")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(item.sources.map { String(format: "%@ %.2f%%", $0.name, $0.percent) }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("ETF 持仓穿透")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct AddCashRow: Identifiable {
    var holding: Holding
    var targetPercent: Double
    var gap: Double
    var quantity: Double
    var amount: Double
    var reason: String
    var id: String { holding.id }
}

private struct FundDCAReplaySummary {
    var code: String
    var firstDate: String
    var lastDate: String
    var contributions: Int
    var invested: Double
    var shares: Double
    var value: Double
    var lumpValue: Double
    var latestNAV: Double
    var dcaReturn: Double { invested > 0 ? (value / invested - 1) * 100 : 0 }
    var lumpReturn: Double { invested > 0 ? (lumpValue / invested - 1) * 100 : 0 }
}

struct FundDCAReplayView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var amountText = "500"
    @State private var months = 24
    private var funds: [Holding] { store.data.holdings.filter { $0.kind == .fund } }
    private var summary: FundDCAReplaySummary? {
        guard let amount = Double(amountText), amount.isFinite, amount > 0,
              !code.isEmpty else { return nil }
        let points = store.data.fundNAVHistory.filter { $0.code == code && $0.nav.isFinite && $0.nav > 0 }.sorted { $0.date < $1.date }
        guard let last = points.last, let lastDate = parse(last.date) else { return nil }
        let startDate = Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: lastDate) ?? .distantPast
        let startKey = dayKey(startDate)
        let selected = points.filter { $0.date >= startKey }
        let grouped = Dictionary(grouping: selected, by: { String($0.date.prefix(7)) })
        let currentMonth = String(dayKey(.now).prefix(7))
        let contributions: [FundNAVPoint] = grouped.keys.sorted().compactMap { month in
            guard let rows = grouped[month]?.sorted(by: { $0.date < $1.date }) else { return nil }
            if let due = rows.first(where: { Int($0.date.suffix(2)) ?? 0 >= 15 }) { return due }
            return month == currentMonth ? nil : rows.last
        }
        guard let first = contributions.first, let end = points.last else { return nil }
        let invested = amount * Double(contributions.count)
        let shares = contributions.reduce(0.0) { $0 + amount / $1.nav }
        let value = shares * end.nav
        let lumpValue = (invested / first.nav) * end.nav
        guard [invested, shares, value, lumpValue].allSatisfy(\.isFinite) else { return nil }
        return FundDCAReplaySummary(code: code, firstDate: first.date, lastDate: end.date,
            contributions: contributions.count, invested: invested, shares: shares,
            value: value, lumpValue: lumpValue, latestNAV: end.nav)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("回放参数") {
                    if funds.isEmpty { Text("先添加场外基金并更新已公布净值。") }
                    else {
                        Picker("基金", selection: $code) { ForEach(funds) { Text("\($0.name) · \($0.code)").tag($0.code) } }
                        TextField("每月投入（元）", text: $amountText).keyboardType(.decimalPad)
                        Picker("回溯区间", selection: $months) {
                            Text("近 1 年").tag(12); Text("近 2 年").tag(24); Text("近 3 年").tag(36); Text("全部历史").tag(1200)
                        }
                    }
                    Text("按每月 15 日或之后首个有净值的日期投入；若历史月份缺少该日期，使用该月最后一条已公布净值。一次性对照在首个定投日投入同样总额。未计申购费、赎回费、税费与现金分红再投。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let result = summary {
                    Section("历史结果 · \(result.firstDate) 至 \(result.lastDate)") {
                        LabeledContent("定投次数", value: "\(result.contributions)")
                        LabeledContent("累计投入", value: result.invested, format: .currency(code: "CNY"))
                        LabeledContent("期末份额", value: result.shares, format: .number.precision(.fractionLength(2)))
                        LabeledContent("按最近净值折算", value: result.value, format: .currency(code: "CNY"))
                        LabeledContent("定投收益率", value: result.dcaReturn / 100, format: .percent.precision(.fractionLength(2)))
                        LabeledContent("一次性买入收益率", value: result.lumpReturn / 100, format: .percent.precision(.fractionLength(2)))
                        LabeledContent("最近已公布净值", value: result.latestNAV, format: .number.precision(.fractionLength(4)))
                    }
                } else if !funds.isEmpty {
                    Section { Text("当前净值历史不足以完成所选区间的回放，或投入金额无效。先刷新基金净值或缩短区间。")
                        .font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("历史定投回放")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { if code.isEmpty { code = funds.first?.code ?? "" } }
        }
    }

    private func parse(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct AddCashSimulationView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var cashText = "10000"
    @State private var reserveText = "10"
    @State private var feeText = "0.10"
    @State private var hasRun = false
    @State private var rows: [AddCashRow] = []
    @State private var investable = 0.0
    @State private var spent = 0.0
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("试算参数") {
                    TextField("新增资金（元）", text: $cashText).keyboardType(.decimalPad)
                    TextField("现金预留（%）", text: $reserveText).keyboardType(.decimalPad)
                    TextField("每笔手续费（元）", text: $feeText).keyboardType(.decimalPad)
                    Button("开始试算") { calculate() }
                    Text("ETF 使用 100 份整手。目标比例读取已设的持仓目标；未设置目标的标的按当前持仓占总资产比例分配。目标金额按总资产（含现金和基金）计算，场外基金不会被建议买卖。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Section { Text(message).foregroundStyle(.orange) } }
                if hasRun {
                    Section("预算") {
                        LabeledContent("可投入", value: investable, format: .currency(code: "CNY"))
                        LabeledContent("计划支出", value: spent, format: .currency(code: "CNY"))
                        LabeledContent("剩余", value: max(0, (Double(cashText) ?? 0) - spent), format: .currency(code: "CNY"))
                    }
                    Section("试算结果") {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(row.holding.name).font(.headline); Spacer(); Text(row.quantity > 0 ? "买 \(row.quantity.formatted(.number.precision(.fractionLength(0)))) 份" : row.reason).foregroundStyle(row.quantity > 0 ? .primary : .secondary) }
                                Text("目标 \(row.targetPercent, specifier: "%.1f")% · 缺口 \(row.gap, format: .currency(code: "CNY"))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if row.quantity > 0 { Text("估算金额 \(row.amount, format: .currency(code: "CNY"))，不含或少量含手续费差异")
                                    .font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }
            .navigationTitle("加仓试算")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func calculate() {
        guard let cash = Double(cashText), cash.isFinite, cash > 0,
              let reserve = Double(reserveText), reserve.isFinite, (0...100).contains(reserve),
              let fee = Double(feeText), fee.isFinite, fee >= 0 else {
            message = "请输入有效资金、0–100% 的预留比例和非负手续费。"; hasRun = false; return
        }
        let holdings = store.data.holdings.filter { $0.kind == .etf && $0.current.isFinite && $0.current > 0 && $0.quantity.isFinite && $0.quantity >= 0 }
        guard !holdings.isEmpty else { message = "没有具备有效价格的 ETF 持仓可供试算。"; hasRun = false; return }
        let currentTotal = store.totalAsset
        investable = cash * (1 - reserve / 100)
        let postInvestmentTotal = currentTotal + investable
        var candidates: [(holding: Holding, target: Double, gap: Double, desired: Double)] = holdings.map { holding in
            let configured = store.data.allocationTargets.first { $0.code == holding.code && $0.kind == holding.kind }?.targetPercent
            let target = configured ?? (currentTotal > 0 ? holding.marketValue / currentTotal * 100 : 0)
            let gap = postInvestmentTotal * target / 100 - holding.marketValue
            let desired = gap > 0 ? max(0, (gap / holding.current / 100).rounded()) * 100 : 0
            return (holding, target, gap, desired)
        }.sorted { $0.gap > $1.gap }
        var remaining = investable
        var output: [AddCashRow] = []
        for candidate in candidates {
            let h = candidate.holding
            let requested = candidate.desired
            let maxLots = max(0, floor((remaining - fee) / h.current / 100)) * 100
            let quantity = min(requested, maxLots)
            let amount = quantity * h.current + (quantity > 0 ? fee : 0)
            remaining -= amount
            output.append(AddCashRow(holding: h, targetPercent: candidate.target, gap: candidate.gap,
                quantity: quantity, amount: amount,
                reason: candidate.gap <= 0 ? "已达目标" : (requested < 100 ? "缺口不足一手" : "预算不足")))
        }
        rows = output; spent = investable - remaining; hasRun = true; message = ""
    }
}

private struct TradePlanInstrument: Identifiable {
    var kind: Holding.Kind
    var code: String
    var name: String
    var id: String { "\(kind.rawValue)|\(code)" }
}

struct TradePlansView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var reviewTarget: TradePlan?

    private var plans: [TradePlan] { store.data.tradePlans.sorted { $0.created > $1.created } }

    var body: some View {
        NavigationStack {
            List {
                if plans.isEmpty { ContentUnavailableView("暂无交易计划", systemImage: "list.clipboard", description: Text("下单前记录理由、参考价与失效条件。")) }
                ForEach(plans) { plan in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(plan.name) · \(plan.side == .buy ? "买入" : "卖出")").font(.headline)
                            Spacer(); Text(statusName(plan.status)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(plan.kind == .fund ? "场外基金" : "ETF/证券") · \(plan.code) · \(plan.created)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("计划价 \(plan.price, format: .number.precision(.fractionLength(3))) · 金额 \(plan.amount, format: .currency(code: "CNY"))")
                            .font(.subheadline)
                        if let target = plan.target { Text("目标价 \(target, format: .number.precision(.fractionLength(3)))") }
                        if let invalid = plan.invalid { Text("失效价 \(invalid, format: .number.precision(.fractionLength(3)))") }
                        if !plan.reason.isEmpty { Text("理由：\(plan.reason)").font(.footnote) }
                        if !plan.trigger.isEmpty { Text("触发条件：\(plan.trigger)").font(.footnote) }
                        if let actualPrice = plan.actualPrice, let actualAmount = plan.actualAmount {
                            let variance = (plan.side == .sell ? plan.price - actualPrice : actualPrice - plan.price) * actualAmount / actualPrice
                            Text("执行价 \(actualPrice, format: .number.precision(.fractionLength(3))) · 相对计划偏差 \(variance, format: .currency(code: "CNY"))")
                                .font(.footnote).foregroundStyle(variance >= 0 ? .green : .orange)
                        }
                        if !plan.review.isEmpty { Text("复盘：\(plan.review)").font(.footnote).foregroundStyle(.secondary) }
                        HStack {
                            if plan.status != .cancelled { Button(plan.status == .reviewed ? "修改复盘" : "记录执行/复盘") { reviewTarget = plan } }
                            if plan.status == .planned { Button("取消计划", role: .destructive) { update(plan, status: .cancelled) } }
                            Button("删除", role: .destructive) { store.data.tradePlans.removeAll { $0.id == plan.id }; store.save() }
                        }.font(.caption)
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("交易计划与复盘")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("新建", systemImage: "plus") { showNew = true } }
            }
            .sheet(isPresented: $showNew) { TradePlanEditor { store.data.tradePlans.append($0); store.save() } }
            .sheet(item: $reviewTarget) { plan in
                TradePlanReviewEditor(plan: plan) { changed in
                    if let index = store.data.tradePlans.firstIndex(where: { $0.id == changed.id }) { store.data.tradePlans[index] = changed; store.save() }
                }
            }
        }
    }

    private func update(_ plan: TradePlan, status: TradePlan.Status) {
        guard let index = store.data.tradePlans.firstIndex(where: { $0.id == plan.id }) else { return }
        store.data.tradePlans[index].status = status; store.save()
    }

    private func statusName(_ status: TradePlan.Status) -> String {
        switch status {
        case .planned: return "计划中"
        case .reviewed: return "已复盘"
        case .cancelled: return "已取消"
        }
    }
}

private struct TradePlanEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    var onSave: (TradePlan) -> Void
    @State private var selectedAsset = ""
    @State private var side: LedgerEntry.Side = .buy
    @State private var amount = ""
    @State private var price = ""
    @State private var target = ""
    @State private var invalid = ""
    @State private var reason = ""
    @State private var trigger = ""
    @State private var reviewDate = Date.now
    @State private var includeReviewDate = false
    @State private var message = ""
    private var instruments: [TradePlanInstrument] {
        let holdings = store.data.holdings.map { TradePlanInstrument(kind: $0.kind, code: $0.code, name: $0.name) }
        let quotes = store.data.quotes.map { TradePlanInstrument(kind: .etf, code: $0.code, name: $0.name) }
        return Array(Dictionary((holdings + quotes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.name < $1.name }
    }
    var body: some View {
        NavigationStack {
            Form {
                if instruments.isEmpty { Text("请先添加自选或持仓。") }
                else {
                    Picker("标的", selection: $selectedAsset) { ForEach(instruments) { Text("\($0.kind == .fund ? "基金" : "ETF/证券") · \($0.name) (\($0.code))").tag($0.id) } }
                    Picker("方向", selection: $side) { Text("买入/申购").tag(LedgerEntry.Side.buy); Text("卖出/赎回").tag(LedgerEntry.Side.sell) }
                    TextField("计划金额（元）", text: $amount).keyboardType(.decimalPad)
                    TextField("参考价/净值", text: $price).keyboardType(.decimalPad)
                    TextField("目标价（可选）", text: $target).keyboardType(.decimalPad)
                    TextField("失效价（可选）", text: $invalid).keyboardType(.decimalPad)
                    Toggle("设置复盘日期", isOn: $includeReviewDate)
                    if includeReviewDate { DatePicker("复盘日期", selection: $reviewDate, displayedComponents: .date) }
                    TextField("交易理由", text: $reason, axis: .vertical).lineLimit(2...4)
                    TextField("触发条件（可选）", text: $trigger, axis: .vertical).lineLimit(2...4)
                    Text("计划只作记录，不会自动交易，也不改变持仓、现金或收益。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !message.isEmpty { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("新建交易计划")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(instruments.isEmpty) }
            }
            .onAppear { if selectedAsset.isEmpty { selectedAsset = instruments.first?.id ?? "" } }
        }
    }
    private func save() {
        guard let amountValue = Double(amount), amountValue.isFinite, amountValue > 0,
              let priceValue = Double(price), priceValue.isFinite, priceValue > 0,
              let instrument = instruments.first(where: { $0.id == selectedAsset }) else { message = "请填写大于零的有效金额和价格。"; return }
        let targetValue = target.isEmpty ? nil : Double(target)
        let invalidValue = invalid.isEmpty ? nil : Double(invalid)
        guard (target.isEmpty || (targetValue?.isFinite == true && (side == .buy ? targetValue! > priceValue : targetValue! < priceValue))),
              (invalid.isEmpty || (invalidValue?.isFinite == true && (side == .buy ? invalidValue! < priceValue : invalidValue! > priceValue))) else {
            message = "目标价和失效价应位于计划价对应方向。"; return
        }
        onSave(TradePlan(id: UUID().uuidString, kind: instrument.kind, code: instrument.code, name: instrument.name,
            side: side, amount: amountValue, price: priceValue, target: targetValue, invalid: invalidValue,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines),
            reviewDate: includeReviewDate ? dateKey(reviewDate) : "", created: dateKey(.now), status: .planned,
            actualPrice: nil, actualAmount: nil, review: ""))
        dismiss()
    }
    private func dateKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
}

private struct TradePlanReviewEditor: View {
    @Environment(\.dismiss) private var dismiss
    var plan: TradePlan
    var onSave: (TradePlan) -> Void
    @State private var actualPrice = ""
    @State private var actualAmount = ""
    @State private var review = ""
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("执行记录") {
                    TextField("实际成交价/净值", text: $actualPrice).keyboardType(.decimalPad)
                    TextField("实际成交金额（元）", text: $actualAmount).keyboardType(.decimalPad)
                    Text("价格和金额需同时填写，或同时留空。执行偏差不是最终交易盈亏。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("复盘") { TextField("记录执行结果与判断依据", text: $review, axis: .vertical).lineLimit(4...8) }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .navigationTitle("交易复盘")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear { actualPrice = plan.actualPrice.map { String($0) } ?? ""; actualAmount = plan.actualAmount.map { String($0) } ?? ""; review = plan.review }
        }
    }
    private func save() {
        let price = actualPrice.isEmpty ? nil : Double(actualPrice)
        let amount = actualAmount.isEmpty ? nil : Double(actualAmount)
        guard actualPrice.isEmpty == actualAmount.isEmpty,
              (actualPrice.isEmpty || (price?.isFinite == true && price! > 0 && amount?.isFinite == true && amount! > 0)) else {
            message = "实际价格与金额请同时填写有效正数，或都留空。"; return
        }
        var changed = plan; changed.actualPrice = price; changed.actualAmount = amount
        changed.review = review.trimmingCharacters(in: .whitespacesAndNewlines); changed.status = .reviewed
        onSave(changed); dismiss()
    }
}

struct AIAnalysisView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var model = ""
    @State private var systemPrompt = ""
    @State private var investmentProfile = InvestmentProfile()
    @State private var token = ""
    @State private var keySaved = false
    @State private var busy = false
    @State private var result = ""
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("投资偏好（会随分析请求发送）") {
                    Picker("交易风格", selection: $investmentProfile.style) {
                        Text("超短线").tag("day"); Text("波段").tag("swing"); Text("中线").tag("mid"); Text("长线定投").tag("long")
                    }
                    Picker("风险偏好", selection: $investmentProfile.risk) {
                        Text("保守").tag("con"); Text("平衡").tag("bal"); Text("激进").tag("agg")
                    }
                    Stepper(value: $investmentProfile.maxPositionPercent, in: 1...100, step: 1) {
                        LabeledContent("单标的仓位上限", value: "\(Int(investmentProfile.maxPositionPercent))%")
                    }
                    TextField("典型持有周期", text: $investmentProfile.horizon)
                    Toggle("关注 ETF 溢价", isOn: $investmentProfile.premiumSensitive)
                    TextField("偏好方向", text: $investmentProfile.preference, axis: .vertical).lineLimit(1...3)
                    TextField("忌讳 / 不做", text: $investmentProfile.avoid, axis: .vertical).lineLimit(1...3)
                    TextField("自己的交易方式", text: $investmentProfile.method, axis: .vertical).lineLimit(2...5)
                    TextField("投资目标", text: $investmentProfile.goal, axis: .vertical).lineLimit(1...3)
                    Button("保存投资偏好") {
                        investmentProfile.maxPositionPercent = min(100, max(1, investmentProfile.maxPositionPercent))
                        store.data.investmentProfile = investmentProfile
                        store.save()
                        message = "投资偏好已保存"
                    }
                }
                Section("接口设置") {
                    TextField("兼容接口基础地址", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("分析要求", text: $systemPrompt, axis: .vertical).lineLimit(3...7)
                    Button("保存接口设置") {
                        var config = store.data.aiAnalysisConfig
                        config.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                        config.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.data.aiAnalysisConfig = config
                        store.save()
                        message = "接口设置已保存"
                    }
                    Text("DeepSeek 默认地址为 https://api.deepseek.com，模型 deepseek-flash；也可以填写其他兼容 Chat Completions 的 HTTPS 接口。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("API 密钥") {
                    SecureField("粘贴 API 密钥", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("安全保存密钥") {
                        do {
                            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                message = "请输入新的密钥；已保存的密钥不会显示在这里。"
                                return
                            }
                            try AIAnalysisService.saveAPIKey(token)
                            token = ""
                            keySaved = AIAnalysisService.hasSavedAPIKey
                            message = "密钥已保存到本机钥匙串"
                        } catch { message = error.localizedDescription }
                    }
                    if keySaved {
                        Button("删除本机已保存密钥", role: .destructive) {
                            do {
                                try AIAnalysisService.saveAPIKey("")
                                keySaved = false
                                message = "本机密钥已删除"
                            } catch { message = error.localizedDescription }
                        }
                    }
                    Text(keySaved ? "密钥已保存在本机钥匙串，不会写入 JSON 备份。" : "请使用你在模型服务商处创建的 API 密钥。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button { Task { await runAnalysis() } } label: {
                        HStack {
                            if busy { ProgressView().padding(.trailing, 4) }
                            Text(busy ? "正在分析…" : "开始 AI 分析")
                        }
                    }.disabled(busy || !keySaved)
                    Text("点击后会把投资偏好、当前持仓、自选行情、参考现金及最近 20 条快照发送至上述接口。请不要在提示中加入账户密码或其他敏感信息。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if !result.isEmpty {
                    Section("分析结果") {
                        Text(result).textSelection(.enabled)
                        Text("模型输出可能有误。价格/净值可能延迟；请核对行情与基金净值，不要仅依据模型文字交易。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("AI 账户分析")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear {
                endpoint = store.data.aiAnalysisConfig.endpoint
                model = store.data.aiAnalysisConfig.model
                systemPrompt = store.data.aiAnalysisConfig.systemPrompt
                investmentProfile = store.data.investmentProfile
                keySaved = AIAnalysisService.hasSavedAPIKey
            }
        }
    }

    @MainActor
    private func runAnalysis() async {
        var config = store.data.aiAnalysisConfig
        config.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        store.data.aiAnalysisConfig = config
        store.save()
        busy = true
        message = ""
        defer { busy = false }
        do { result = try await AIAnalysisService.analyze(config: config, portfolio: store.data) }
        catch { message = error.localizedDescription }
    }
}

struct AllocationTargetEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    let targetPercent: Double?
    @State private var percent = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("标的", value: "\(holding.name) · \(holding.code)")
                TextField("目标仓位（%）", text: $percent).keyboardType(.decimalPad)
                Text("当前仓位 \(store.allocationActualPercent(for: holding), specifier: "%.2f")%。保存后仅计算偏差金额，不会修改持仓或现金。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                if targetPercent != nil {
                    Button("删除目标", role: .destructive) { store.removeAllocationTarget(for: holding); dismiss() }
                }
            }
            .navigationTitle("设置目标仓位")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear { if percent.isEmpty, let targetPercent { percent = String(targetPercent) } }
        }
    }
    private func save() {
        guard let value = Double(percent) else { error = "请输入 0 到 100 之间的百分比。"; return }
        do { try store.saveAllocationTarget(for: holding, percent: value); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct GridInstrument: Identifiable {
    var code: String
    var name: String
    var price: Double
    var id: String { code }
}

struct DayGridView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var capital = "5000"
    @State private var anchor = ""
    @State private var step = "0.6"
    @State private var levels = "5"
    @State private var fee = "0.1"
    @State private var selectedDay = ""
    @State private var result: GridReplayResult?
    @State private var message = ""
    @State private var recommendationText = ""
    @State private var showImporter = false

    private var instruments: [GridInstrument] {
        let etfs = store.data.holdings.filter { $0.kind == .etf }.map { GridInstrument(code: $0.code, name: $0.name, price: $0.current) }
        let watches = store.data.quotes.map { GridInstrument(code: $0.code, name: $0.name, price: $0.price) }
        let plans = store.data.dayGridPlans.map { GridInstrument(code: $0.code, name: $0.name, price: $0.anchor) }
        return Array(Dictionary((etfs + watches + plans).map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.code < $1.code }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标的与参数") {
                    if instruments.isEmpty {
                        Text("先在自选或 ETF 持仓中添加标的。")
                    } else {
                        Picker("标的", selection: $code) {
                            ForEach(instruments) { item in Text("\(item.name) · \(item.code)").tag(item.code) }
                        }
                        .onChange(of: code) { _, value in
                            if let item = instruments.first(where: { $0.code == value }) {
                                name = item.name
                                if anchor.isEmpty || anchor == "0" { anchor = item.price > 0 ? String(format: "%.3f", item.price) : "" }
                            }
                        }
                    }
                    TextField("计划资金（元）", text: $capital).keyboardType(.decimalPad)
                    TextField("网格中枢价", text: $anchor).keyboardType(.decimalPad)
                    TextField("每档间距（%）", text: $step).keyboardType(.decimalPad)
                    TextField("上下档数（各侧）", text: $levels).keyboardType(.numberPad)
                    TextField("每笔费用（元）", text: $fee).keyboardType(.decimalPad)
                    Button("根据历史分时生成规则建议") { suggestParameters() }.disabled(code.isEmpty)
                    if !recommendationText.isEmpty { Text(recommendationText).font(.footnote).foregroundStyle(.secondary) }
                    Button("保存/更新本地计划") { savePlan() }.disabled(code.isEmpty)
                    Text("每档按 100 份整数手模拟。每档资金小于 1 手时会显示资金不足原因；计划仍可保存，调整资金或减少档数即可。计划预设不要求市场已开盘。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("分时数据") {
                    Button("导入分时 CSV") { showImporter = true }
                    Text("CSV 支持 code,date,time,price,volume 或 code,timestamp,price；无 code 列时使用当前选择标的；timestamp/time 列需包含完整日期和时间（yyyy-MM-dd HH:mm[:ss]）。应用在前台且取得有效报价时才采集；已保存的分时历史不会按交易日数自动删除。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !store.gridTradingDays.isEmpty {
                        Picker("复盘日期", selection: $selectedDay) {
                            ForEach(store.gridTradingDays, id: \.self) { Text($0).tag($0) }
                        }
                        Button("复盘所选日期") { runReplay() }.disabled(code.isEmpty || selectedDay.isEmpty)
                    }
                }
                if let result {
                    Section("路径模拟结果 · \(result.day)") {
                        LabeledContent("模拟盈亏", value: result.profit, format: .currency(code: "CNY"))
                        LabeledContent("买入 / 卖出", value: "\(result.buyCount) / \(result.sellCount) 笔")
                        LabeledContent("估算费用", value: result.fees, format: .currency(code: "CNY"))
                        LabeledContent("分时覆盖", value: result.coverage, format: .percent.precision(.fractionLength(0)))
                        Text(result.fills == 0 ? "该日没有触发网格成交。若资金不足以买入 100 份一手、网格间距超出当日波动，或数据缺点，结果可能没有代表性。" : "回放按时间顺序计算，含逐笔固定费用；不含排队、成交量、滑点、涨跌停和真实券商规则。历史最佳参数会有过拟合，不能直接当作明日建议。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !message.isEmpty { Section { Text(message).font(.footnote) } }
                Section("已保存计划") {
                    if store.data.dayGridPlans.isEmpty { Text("暂无计划") }
                    ForEach(store.data.dayGridPlans) { plan in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(plan.name) · \(plan.code)").font(.headline)
                            Text("资金 \(plan.capital, format: .number.precision(.fractionLength(0))) · 中枢 \(plan.anchor, format: .number.precision(.fractionLength(3))) · 间距 \(plan.stepPercent * 100, format: .number.precision(.fractionLength(2)))% · 每档约 \(floor(plan.capital / Double(plan.levelsEachSide * 2 + 2) / (plan.anchor * 100)) * 100, format: .number.precision(.fractionLength(0))) 份")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("载入参数") { loadPlan(plan) }
                            Button("删除计划", role: .destructive) { store.removeGridPlan(plan) }
                        }
                    }
                }
                if !store.data.legacyGridArchives.isEmpty {
                    Section("旧版网格记录（只读归档）") {
                        ForEach(store.data.legacyGridArchives) { record in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(record.name) · \(record.code)")
                                Text("\(record.horizon) · \(record.mode) · \(record.status) · \(record.created)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if record.capital > 0 {
                                    Text("计划资金 \(record.capital, format: .currency(code: "CNY")) · 原网格 \(record.lower, format: .number.precision(.fractionLength(3)))–\(record.upper, format: .number.precision(.fractionLength(3))) · 每档 \(record.quantity, format: .number.precision(.fractionLength(0))) 份")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("旧版每条网格记录及其成交、模拟资金等字段以原始 JSON 保留；符合日内参数条件的已另外转换为可载入回放的计划。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !store.data.legacyShadowArchives.isEmpty {
                    Section("旧版影子盘历史与自动模拟") {
                        ForEach(store.data.legacyShadowArchives) { record in
                            DisclosureGroup("\(record.name) · \(record.code)") {
                                LabeledContent("模拟状态", value: record.closed ? "已结束" : (record.active ? "运行中" : "已暂停"))
                                if !record.closed {
                                    Button(record.active ? "暂停影子模拟" : "恢复影子模拟") {
                                        store.setLegacyShadowActive(record, active: !record.active)
                                    }
                                }
                                LabeledContent("影子账户盈亏（末次行情估算）", value: record.lastEquityChange, format: .currency(code: "CNY"))
                                LabeledContent("相对初始持有", value: record.lastEquityChange - record.holdOnlyChange, format: .currency(code: "CNY"))
                                LabeledContent("累计已实现", value: record.realizedPnL, format: .currency(code: "CNY"))
                                LabeledContent("估算费用", value: record.totalFees, format: .currency(code: "CNY"))
                                LabeledContent("模拟买 / 卖", value: "\(record.buys) / \(record.sells)")
                                if record.scoredSells > 0 {
                                    LabeledContent("旧记录卖出胜率", value: "\(Double(record.wins) / Double(record.scoredSells) * 100, format: .number.precision(.fractionLength(1)))%")
                                }
                                if !record.days.isEmpty {
                                    DisclosureGroup("每日摘要（最近 20 日）") {
                                        ForEach(Array(record.days.suffix(20).reversed())) { day in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(day.day)
                                                Text("买 \(day.buys) / 卖 \(day.sells) · 费用 \(day.fees, format: .currency(code: "CNY")) · 已实现 \(day.realizedPnL, format: .currency(code: "CNY"))")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                if !record.fills.isEmpty {
                                    DisclosureGroup("成交明细（最近 20 笔，共 \(record.fills.count) 笔）") {
                                        ForEach(Array(record.fills.suffix(20).reversed())) { fill in
                                            Text("\(fill.day) \(fill.time) · \(fill.side == "buy" ? "买" : "卖") \(fill.quantity, format: .number.precision(.fractionLength(0))) 份 @ \(fill.price, format: .number.precision(.fractionLength(3))) · 费用 \(fill.fee, format: .currency(code: "CNY"))")
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        Text("影子盘使用隔离的虚拟资金，前台有效行情更新时按网格档位模拟，不会计入原生真实持仓或现金。价格、费用与胜率均为估算，不能代表可成交结果；暂停期间只更新参考价、不记模拟成交，恢复时会重新建立行情基准。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("日内网格 / 复盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                if code.isEmpty, let first = instruments.first { code = first.code; name = first.name; anchor = first.price > 0 ? String(format: "%.3f", first.price) : "" }
                if selectedDay.isEmpty { selectedDay = store.gridTradingDays.first ?? "" }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: false) { response in
                do {
                    guard let url = try response.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let count = try store.importIntradayCSV(Data(contentsOf: url), fallbackCode: code)
                    selectedDay = store.gridTradingDays.first ?? ""
                    message = "已导入 \(count) 个分时点。"
                } catch { message = error.localizedDescription }
            }
        }
    }

    private func savePlan() {
        do {
            guard let capitalValue = Double(capital), let anchorValue = Double(anchor), let stepValue = Double(step), let levelValue = Int(levels), let feeValue = Double(fee) else { throw GridError.invalidPlan }
            let chosen = instruments.first { $0.code == code }
            try store.saveGridPlan(code: code, name: chosen?.name ?? name, capital: capitalValue, anchor: anchorValue, stepPercent: stepValue, levels: levelValue, feePerOrder: feeValue)
            message = "计划已保存，不会占用或改变主账户资金。"
        } catch { message = error.localizedDescription }
    }

    private func loadPlan(_ plan: DayGridPlan) {
        code = plan.code; name = plan.name
        capital = String(format: "%.2f", plan.capital)
        anchor = String(format: "%.4f", plan.anchor)
        step = String(format: "%.3f", plan.stepPercent * 100)
        levels = String(plan.levelsEachSide)
        fee = String(format: "%.2f", plan.feePerOrder)
        recommendationText = "已载入本地参数。"
    }

    private func suggestParameters() {
        guard let capitalValue = Double(capital), let feeValue = Double(fee) else {
            recommendationText = "先填写有效的计划资金和每笔费用。"; return
        }
        guard let suggestion = store.gridRecommendation(code: code, capital: capitalValue, feePerOrder: feeValue) else {
            recommendationText = "本机暂时没有至少 3 个覆盖合格的交易日，或现有资金/费用不足以支持至少一档。先采集或导入完整分时数据。"; return
        }
        anchor = String(format: "%.3f", suggestion.anchor)
        step = String(format: "%.3f", suggestion.stepPercent)
        levels = String(suggestion.levels)
        recommendationText = "规则评分 \(suggestion.score)/100 · \(suggestion.summary) 这是基于历史数据的参数参考，不是 AI 预测，也不保证未来收益。"
    }

    private func runReplay() {
        guard let plan = store.data.dayGridPlans.first(where: { $0.code == code }) else { message = "先保存该标的的网格计划。"; return }
        guard let replay = store.replayGrid(plan: plan, day: selectedDay) else { message = "该日分时覆盖不足 70% 或存在超过 10 分钟的缺口，无法给出可信回放。"; return }
        result = replay
        if replay.fills == 0 {
            let budget = plan.capital / Double(plan.levelsEachSide * 2 + 2)
            let oneLot = plan.anchor * 100 + plan.feePerOrder
            message = budget < oneLot ? "资金不够：每档约 \(budget, format: .currency(code: "CNY"))，按当前中枢买入 100 份约需 \(oneLot, format: .currency(code: "CNY"))。减少档数或增加计划资金后复盘。" : "数据中没有穿越网格档位；也可能是该日分时覆盖不足。"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: PortfolioStore
    @AppStorage("guanpan.native.backgroundRefresh.enabled") private var backgroundRefreshEnabled = false
    @AppStorage(NASSyncService.urlKey) private var nasURL = ""
    @AppStorage(NASSyncService.automaticKey) private var nasAutoSync = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var confirmNASDownload = false
    @State private var confirmNASUpload = false
    @State private var checkingNAS = false
    @State private var nasToken = ""
    @State private var message = ""
    @State private var notificationBusy = false
    @State private var notificationEnabled = false
    var body: some View {
        NavigationStack {
            Form {
                Picker("外观", selection: Binding(get: { store.appearance }, set: { store.appearance = $0 })) {
                    Text("跟随系统").tag(AppAppearance.system); Text("浅色").tag(AppAppearance.light); Text("深色").tag(AppAppearance.dark)
                }
                Section("现金账本") {
                    LabeledContent("当前参考现金", value: store.data.cash, format: .currency(code: "CNY"))
                    Text("现金余额请在“资产”页记录转入/转出，保留现金流历史，避免影响快照收益计算。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("交易默认联动现金", isOn: Binding(get: { store.data.cashLinkedByDefault }, set: { store.data.cashLinkedByDefault = $0; store.save() }))
                }
                Section("行情刷新") {
                    Toggle("自动刷新行情", isOn: Binding(get: { store.data.quoteRefreshSeconds > 0 }, set: { store.data.quoteRefreshSeconds = $0 ? max(10, store.data.quoteRefreshSeconds) : 0; store.save() }))
                    Stepper(value: Binding(get: { max(10, store.data.quoteRefreshSeconds) }, set: { store.data.quoteRefreshSeconds = min(600, max(10, $0)); store.save() }), in: 10...600, step: 10) {
                        LabeledContent("自动刷新间隔", value: store.data.quoteRefreshSeconds > 0 ? "\(store.data.quoteRefreshSeconds) 秒" : "已关闭")
                    }.disabled(store.data.quoteRefreshSeconds == 0)
                    Toggle("允许系统安排后台刷新", isOn: $backgroundRefreshEnabled)
                    Text("前台按设置间隔刷新；后台刷新由 iOS 自主安排，时间和频率不保证。后台只尝试更新行情并触发已授权的本地价格提醒，不采集分时、不运行影子盘，也不刷新基金净值。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("数据备份") {
                    Button("导出 JSON 备份") { showExporter = true }
                    Button("导入 JSON 备份") { showImporter = true }
                    Text("导入会整体替换原生版本地账本。可选择原生 JSON 备份或观盘 Pro 网页版完整 JSON 备份。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("NAS 多设备同步") {
                    TextField("服务器地址，例如 http://192.168.1.20:8787", text: $nasURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("同步口令", text: $nasToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("自动同步", isOn: $nasAutoSync)
                    HStack {
                        Button(checkingNAS ? "正在检查…" : "测试连接") { testNAS() }.disabled(checkingNAS)
                        Spacer()
                        Button("安全同步") { Task { await store.synchronizeNASSafely() } }
                    }
                    HStack {
                        Button("从 NAS 下载") { confirmNASDownload = true }
                        Spacer()
                        Button("上传到 NAS") { confirmNASUpload = true }
                    }
                    Text(store.nasSyncStatus).font(.footnote).foregroundStyle(.secondary)
                    Text("自动同步会在应用启动、回到前台及本机数据变更后运行。若两台设备都改过数据，会暂停并提示冲突。手动下载或上传会覆盖另一端账本，请先确认方向。原生空间为空时会先迁入 NAS 上可识别的网页账本；之后网页与原生各自同步，原生改动不会反向转换回网页格式。分时和日线缓存随原生账本同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !store.data.legacySettingsArchives.isEmpty {
                    Section("旧版设置与计划备查") {
                        ForEach(store.data.legacySettingsArchives) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.subheadline)
                                Text(item.rawJSON).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(5).textSelection(.enabled)
                            }
                        }
                        Text("旧版个人偏好、未来交易计划和休市日已保留作参考；这些旧计划不会在原生版自动执行。旧网页 AI 凭证不会迁入。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("系统通知") {
                    Button(notificationBusy ? "正在请求权限…" : "开启并测试本地通知") { enableNotifications() }
                        .disabled(notificationBusy)
                    Text(notificationEnabled ? "已获得通知权限。可安排本机提醒；行情后台监控和远程推送尚未实现。" : "通知权限由 iOS 管理。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("设置")
            .onAppear { BackgroundQuoteRefresh.configure(store: store) }
            .onChange(of: backgroundRefreshEnabled) { _, _ in BackgroundQuoteRefresh.configure(store: store) }
            .onChange(of: store.data.quoteRefreshSeconds) { _, _ in BackgroundQuoteRefresh.configure(store: store) }
            .onAppear { nasToken = NASCredentialStore.load() ?? "" }
            .onChange(of: nasURL) { _, _ in store.configureNASSync() }
            .onChange(of: nasToken) { _, value in
                _ = NASCredentialStore.save(value)
                store.configureNASSync()
            }
            .onChange(of: nasAutoSync) { _, _ in store.configureNASSync() }
            .confirmationDialog("从 NAS 下载会覆盖本机原生账本。确认已备份本机数据？", isPresented: $confirmNASDownload, titleVisibility: .visible) {
                Button("下载并覆盖本机", role: .destructive) { Task { await store.downloadFromNAS() } }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("上传会覆盖 NAS 上的原生账本，其他原生设备下次同步会收到这份数据。确认已核对？", isPresented: $confirmNASUpload, titleVisibility: .visible) {
                Button("上传并覆盖 NAS", role: .destructive) { Task { await store.uploadToNAS(allowEmptyOverwrite: true) } }
                Button("取消", role: .cancel) { }
            }
            .fileExporter(isPresented: $showExporter, document: PortfolioBackup(data: store.data, intradayBars: store.intradayBars, dailyBars: store.dailyBars.values.flatMap { $0 }), contentType: .json, defaultFilename: "观盘Pro原生备份") { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try Data(contentsOf: url)
                    if let package = try? JSONDecoder().decode(NativeBackupEnvelope.self, from: bytes) {
                        store.replaceData(package.data, intradayBars: package.intradayBars, dailyBars: package.dailyBars)
                        message = "原生备份已恢复（含 \(package.intradayBars.count) 个分时点、\(package.dailyBars.count) 个日线点）"
                    } else {
                        let migrated = try LegacyMigration.decodePackage(bytes)
                        store.replaceData(migrated.data, intradayBars: migrated.intradayBars)
                        message = "网页备份已迁移：\(migrated.data.fundDCAPlans.count) 个定投计划、\(migrated.data.fundNAVHistory.count) 个基金净值点、\(migrated.data.legacyDCAEvents.count) 个待核对定投期次、\(migrated.data.legacyGridArchives.count) 条旧网格记录（影子盘 \(migrated.data.legacyShadowArchives.count) 条）、\(migrated.intradayBars.count) 个分时点、\(migrated.data.quoteAlerts.count) 条价格提醒"
                    }
                } catch { message = "导入失败：\(error.localizedDescription)" }
            }
        }
    }

    private func enableNotifications() {
        notificationBusy = true
        Task {
            do {
                let allowed = try await NativeNotifications.requestPermission()
                notificationEnabled = allowed
                if allowed { try await NativeNotifications.send(title: "观盘 Pro", body: "iPhone 本地通知已开启。") }
                message = allowed ? "已安排一条测试提醒" : "通知未获授权，请在 iPhone 设置中允许通知"
            } catch { message = "通知设置失败：\(error.localizedDescription)" }
            notificationBusy = false
        }
    }

    private func testNAS() {
        checkingNAS = true
        Task { @MainActor in
            defer { checkingNAS = false }
            do {
                _ = try await NASSyncService.ping(base: nasURL, token: nasToken)
                store.nasSyncStatus = "NAS 连接正常，原生同步接口可用"
            } catch { store.nasSyncStatus = "连接失败：\(error.localizedDescription)" }
        }
    }
}

struct NativeBackupEnvelope: Codable {
    var formatVersion = 2
    var data: PortfolioData
    var intradayBars: [IntradayBar]
    var dailyBars: [DailyBar]

    init(data: PortfolioData, intradayBars: [IntradayBar], dailyBars: [DailyBar] = []) {
        self.data = data
        self.intradayBars = intradayBars
        self.dailyBars = dailyBars
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, data, intradayBars, dailyBars }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        data = try container.decode(PortfolioData.self, forKey: .data)
        intradayBars = try container.decodeIfPresent([IntradayBar].self, forKey: .intradayBars) ?? []
        dailyBars = try container.decodeIfPresent([DailyBar].self, forKey: .dailyBars) ?? []
    }
}

struct PortfolioBackup: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: PortfolioData
    var intradayBars: [IntradayBar]
    var dailyBars: [DailyBar]
    init(data: PortfolioData, intradayBars: [IntradayBar], dailyBars: [DailyBar] = []) { self.data = data; self.intradayBars = intradayBars; self.dailyBars = dailyBars }
    init(configuration: ReadConfiguration) throws {
        guard let raw = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        if let package = try? JSONDecoder().decode(NativeBackupEnvelope.self, from: raw) {
            data = package.data; intradayBars = package.intradayBars; dailyBars = package.dailyBars
        } else {
            data = try JSONDecoder().decode(PortfolioData.self, from: raw); intradayBars = []; dailyBars = []
        }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(NativeBackupEnvelope(data: data, intradayBars: intradayBars, dailyBars: dailyBars)))
    }
}
