import Foundation

struct LedgerHealthFinding: Identifiable {
    enum Severity: Int { case normal = 0, warning = 1, error = 2 }
    var id = UUID()
    var severity: Severity
    var category: String
    var title: String
    var detail: String
}

@MainActor
extension PortfolioStore {
    /// Read-only integrity checks. Findings are advisory and never rewrite the ledger.
    func ledgerHealthReport() -> [LedgerHealthFinding] {
        var findings: [LedgerHealthFinding] = []
        func add(_ severity: LedgerHealthFinding.Severity, _ category: String, _ title: String, _ detail: String = "") {
            findings.append(LedgerHealthFinding(severity: severity, category: category, title: title, detail: detail))
        }
        func duplicates(_ values: [String]) -> [String] {
            let counts = Dictionary(grouping: values.filter { !$0.isEmpty }, by: { $0 }).mapValues(\.count)
            return counts.filter { $0.value > 1 }.keys.sorted()
        }

        let invalidHoldings = data.holdings.filter {
            $0.code.isEmpty || !$0.quantity.isFinite || $0.quantity < 0 || !$0.cost.isFinite || $0.cost < 0
                || !$0.current.isFinite || $0.current < 0
        }
        let duplicateHoldings = duplicates(data.holdings.map { "\($0.kind.rawValue):\($0.code)" })
        if !invalidHoldings.isEmpty {
            add(.error, "持仓", "持仓存在无效份额或价格", invalidHoldings.prefix(5).map(\.name).joined(separator: "、"))
        }
        if !duplicateHoldings.isEmpty {
            add(.error, "持仓", "持仓代码重复", duplicateHoldings.joined(separator: "、"))
        }
        if invalidHoldings.isEmpty && duplicateHoldings.isEmpty {
            add(.normal, "持仓", "持仓基础字段正常", "未发现负数、无效价格或同类重复代码。")
        }
        if data.investmentProfile.maxPositionPercent.isFinite,
           data.investmentProfile.maxPositionPercent > 0, totalAsset > 0 {
            let overLimit = data.holdings.filter { $0.marketValue / totalAsset * 100 > data.investmentProfile.maxPositionPercent }
            if !overLimit.isEmpty {
                let title = String(format: "有 %d 项持仓超过个人仓位上限 %.1f%%", overLimit.count, data.investmentProfile.maxPositionPercent)
                let detail = overLimit.prefix(5).map { String(format: "%@ %.1f%%", $0.name, $0.marketValue / totalAsset * 100) }.joined(separator: "、")
                add(.warning, "集中度", title, detail)
            }
        }

        let invalidLedger = data.ledger.filter {
            $0.code.isEmpty || !$0.quantity.isFinite || $0.quantity <= 0 || !$0.price.isFinite || $0.price <= 0
                || !$0.fee.isFinite || $0.fee < 0 || !$0.realizedPnL.isFinite
        }
        let duplicateLedgerIDs = duplicates(data.ledger.map { $0.id.uuidString })
        if !invalidLedger.isEmpty { add(.error, "交易流水", "有 \(invalidLedger.count) 笔无效交易数字", "检查代码、份额、成交价和手续费。") }
        if !duplicateLedgerIDs.isEmpty { add(.error, "交易流水", "交易流水 ID 重复", duplicateLedgerIDs.prefix(5).joined(separator: "、")) }
        if invalidLedger.isEmpty && duplicateLedgerIDs.isEmpty { add(.normal, "交易流水", "交易流水字段正常", "共检查 \(data.ledger.count) 笔。") }

        let duplicatePlanIDs = duplicates(data.tradePlans.map(\.id))
        let invalidPlans = data.tradePlans.filter { plan in
            guard !plan.code.isEmpty, plan.amount.isFinite, plan.amount > 0, plan.price.isFinite, plan.price > 0 else { return true }
            if let target = plan.target, !target.isFinite || (plan.side == .buy ? target <= plan.price : target >= plan.price) { return true }
            if let invalid = plan.invalid, !invalid.isFinite || (plan.side == .buy ? invalid >= plan.price : invalid <= plan.price) { return true }
            return false
        }
        if !invalidPlans.isEmpty { add(.error, "交易计划", "有 \(invalidPlans.count) 条计划字段无效", "检查计划金额、参考价、目标价和失效价。") }
        if !duplicatePlanIDs.isEmpty { add(.error, "交易计划", "交易计划 ID 重复", duplicatePlanIDs.prefix(5).joined(separator: "、")) }
        if invalidPlans.isEmpty && duplicatePlanIDs.isEmpty { add(.normal, "交易计划", "交易计划字段正常", "共检查 \(data.tradePlans.count) 条。") }

        let invalidFunds = data.holdings.filter {
            $0.kind == .fund && ($0.code.isEmpty || !$0.quantity.isFinite || $0.quantity < 0
                || !$0.cost.isFinite || $0.cost < 0 || !$0.current.isFinite || $0.current < 0)
        }
        let duplicateFundCodes = duplicates(data.holdings.filter { $0.kind == .fund }.map(\.code))
        if !invalidFunds.isEmpty { add(.error, "基金", "基金持仓存在无效数字", invalidFunds.prefix(5).map(\.name).joined(separator: "、")) }
        if !duplicateFundCodes.isEmpty { add(.error, "基金", "基金代码重复", duplicateFundCodes.joined(separator: "、")) }
        let invalidFundTrades = data.fundTransactions.filter { trade in
            let invalidAllocation = trade.redemptionLots.map { lots in
                !lots.allSatisfy { isDayString($0.purchaseDate) && $0.shares.isFinite && $0.shares > 0 }
                    || abs(lots.reduce(0) { $0 + $1.shares } - trade.quantity) > 0.02
            } ?? false
            return trade.code.isEmpty || !trade.quantity.isFinite || trade.quantity < 0 || !trade.nav.isFinite || trade.nav < 0
                || !trade.amount.isFinite || trade.amount < 0 || !trade.fee.isFinite || trade.fee < 0 || invalidAllocation
        }
        if !invalidFundTrades.isEmpty { add(.error, "基金", "基金流水有 \(invalidFundTrades.count) 笔无效数字", "检查代码、份额、净值、金额和费用。") }
        let stalePending = data.fundTransactions.filter { trade in
            guard trade.status == .pending, let date = dayDate(trade.requestDate) else { return false }
            return (Calendar(identifier: .gregorian).dateComponents([.day], from: date, to: .now).day ?? 0) > 30
        }
        if !stalePending.isEmpty {
            add(.warning, "基金", "有 \(stalePending.count) 笔待确认流水超过 30 天", "最早日期：\(stalePending.map(\.requestDate).sorted().first ?? "未知")。请按销售平台实际确认情况核对。")
        }
        let duplicateFundTradeIDs = duplicates(data.fundTransactions.map { $0.id.uuidString })
        if !duplicateFundTradeIDs.isEmpty { add(.error, "基金", "基金流水 ID 重复", duplicateFundTradeIDs.prefix(5).joined(separator: "、")) }
        if invalidFunds.isEmpty && duplicateFundCodes.isEmpty && invalidFundTrades.isEmpty && stalePending.isEmpty && duplicateFundTradeIDs.isEmpty {
            add(.normal, "基金", "基金基础账本正常", "未发现无效数字、重复持仓或长期待确认流水。")
        }

        if !data.cash.isFinite || data.cash < 0 {
            add(.error, "现金", "参考现金无效", "当前值：\(data.cash)")
        } else { add(.normal, "现金", "参考现金为有效非负数", "余额：\(data.cash.formatted(.currency(code: "CNY")))。") }
        let invalidCashFlows = data.cashFlows.filter { !$0.amount.isFinite || !$0.date.timeIntervalSince1970.isFinite }
        if !invalidCashFlows.isEmpty { add(.error, "现金", "现金流水有 \(invalidCashFlows.count) 条无效记录", "检查金额与日期。") }
        let duplicateCashIDs = duplicates(data.cashFlows.map { $0.id.uuidString })
        if !duplicateCashIDs.isEmpty { add(.error, "现金", "现金流水 ID 重复", duplicateCashIDs.prefix(5).joined(separator: "、")) }

        let duplicateSnapshotDays = duplicates(data.snapshots.map(\.date))
        let invalidSnapshots = data.snapshots.filter { !isDayString($0.date) || !$0.total.isFinite || $0.total < 0 || !$0.cash.isFinite }
        if !duplicateSnapshotDays.isEmpty { add(.warning, "快照", "有 \(duplicateSnapshotDays.count) 个日期存在重复快照", duplicateSnapshotDays.prefix(5).joined(separator: "、")) }
        if !invalidSnapshots.isEmpty { add(.error, "快照", "有 \(invalidSnapshots.count) 条无效快照", "日期或总资产格式异常。") }
        if duplicateSnapshotDays.isEmpty && invalidSnapshots.isEmpty { add(.normal, "快照", "资产快照结构正常", "共 \(data.snapshots.count) 条。") }

        let navKeys = data.fundNAVHistory.map { "\($0.code)-\($0.date)" }
        let duplicateNAVs = duplicates(navKeys)
        let invalidNAVs = data.fundNAVHistory.filter { $0.code.isEmpty || !isDayString($0.date) || !$0.nav.isFinite || $0.nav <= 0 }
        if !duplicateNAVs.isEmpty { add(.warning, "净值历史", "基金净值有重复日期", duplicateNAVs.prefix(5).joined(separator: "、")) }
        if !invalidNAVs.isEmpty { add(.error, "净值历史", "基金净值历史有 \(invalidNAVs.count) 个无效点", "检查代码、日期和净值。") }
        if duplicateNAVs.isEmpty && invalidNAVs.isEmpty { add(.normal, "净值历史", "基金净值历史结构正常", "共 \(data.fundNAVHistory.count) 个点。") }

        return findings.sorted { $0.severity.rawValue > $1.severity.rawValue }
    }

    private func dayDate(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }

    private func isDayString(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let parsed = dayDate(value) else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: parsed) == value
    }
}
