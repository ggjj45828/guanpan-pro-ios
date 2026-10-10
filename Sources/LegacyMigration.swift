import Foundation

enum LegacyMigrationError: LocalizedError {
    case invalidBackup
    var errorDescription: String? { "无法识别这份观盘 Pro 备份格式。" }
}

struct LegacyMigrationResult {
    var data: PortfolioData
    var intradayBars: [IntradayBar]
}

enum LegacyMigration {
    static func decode(_ bytes: Data) throws -> PortfolioData {
        try decodePackage(bytes).data
    }

    static func decodePackage(_ bytes: Data) throws -> LegacyMigrationResult {
        let decoder = JSONDecoder()
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LegacyMigrationError.invalidBackup }
        let nativeMarkers: Set<String> = ["quotes", "holdings", "snapshots", "cashFlows", "fundNAVHistory", "fundTransactions", "ledger"]
        let markerCount = nativeMarkers.filter { root[$0] != nil }.count
        let hasNativeCollections = ["quotes", "holdings", "snapshots", "ledger"].contains { root[$0] is [[String: Any]] }
        // PortfolioData now supplies defaults for missing fields to support schema upgrades.
        // Require clear native-backup structure first so arbitrary/empty JSON cannot decode as
        // an empty account and silently replace the user's local data.
        if markerCount >= 2, hasNativeCollections,
           let current = try? decoder.decode(PortfolioData.self, from: bytes) {
            return LegacyMigrationResult(data: current, intradayBars: [])
        }
        let db = root["db"] as? [String: Any] ?? root
        var result = PortfolioData()
        result.cash = number(root["cash"]) ?? 0

        // Map legacy preferences with direct native equivalents. The full legacy
        // settings archive below keeps unsupported preferences inspectable.
        if let cfg = root["cfg"] as? [String: Any], let cashLink = number(cfg["cashLink"]) {
            result.cashLinkedByDefault = cashLink != 0
        }
        if let cfg = root["cfg"] as? [String: Any], let seconds = number(cfg["auto"]), seconds.isFinite {
            let interval = Int(min(600, max(0, seconds)))
            result.quoteRefreshSeconds = interval == 0 && cfg["cfgV"] == nil ? 10 : interval
        }
        if let theme = string(root["theme"])?.lowercased() {
            switch theme {
            case "light", "paper", "mint": result.appearance = .light
            case "dark", "oled", "blue", "green", "purple", "sakura", "cyber", "amber", "coffee", "graphite": result.appearance = .dark
            default: break
            }
        }
        if let profile = db["profile"] as? [String: Any] {
            var migrated = InvestmentProfile()
            migrated.style = ["day", "swing", "mid", "long"].contains(string(profile["style"]) ?? "") ? (string(profile["style"]) ?? "swing") : "swing"
            migrated.risk = ["con", "bal", "agg"].contains(string(profile["risk"]) ?? "") ? (string(profile["risk"]) ?? "bal") : "bal"
            if let maxw = number(profile["maxw"]), maxw.isFinite { migrated.maxPositionPercent = min(100, max(1, maxw)) }
            migrated.horizon = string(profile["horizon"]) ?? migrated.horizon
            migrated.premiumSensitive = (number(profile["prem"]) ?? 1) != 0
            migrated.preference = string(profile["like"]) ?? ""
            migrated.avoid = string(profile["hate"]) ?? ""
            migrated.method = string(profile["way"]) ?? ""
            migrated.goal = string(profile["goal"]) ?? ""
            result.investmentProfile = migrated
        }

        let watch = db["watch"] as? [[String: Any]] ?? []
        result.quotes = watch.compactMap { row in
            guard let code = string(row["code"]), !code.isEmpty else { return nil }
            return Quote(code: code, name: string(row["name"]) ?? code,
                         price: number(row["price"]) ?? 0, changePct: (number(row["pct"]) ?? 0) / 100, updatedAt: nil)
        }

        let etfs = db["hold"] as? [[String: Any]] ?? []
        for row in etfs {
            guard let code = string(row["code"]), !code.isEmpty else { continue }
            let cost = number(row["cost"]) ?? 0
            result.holdings.append(Holding(code: code, name: string(row["name"]) ?? code,
                quantity: number(row["num"]) ?? 0, cost: cost,
                current: number(row["price"]) ?? cost, kind: .etf))
        }

        if let targets = root["tgt"] as? [String: Any] {
            for (code, value) in targets {
                guard let target = value as? [String: Any] else { continue }
                let name = string(etfs.first(where: { string($0["code"]) == code })?["name"])
                    ?? string(watch.first(where: { string($0["code"]) == code })?["name"]) ?? code
                if let takeProfit = number(target["tp"]), takeProfit > 0 {
                    result.quoteAlerts.append(QuoteAlert(code: code, name: name, target: takeProfit,
                        direction: .above, enabled: true, lastTriggeredAt: nil))
                }
                if let stopLoss = number(target["sl"]), stopLoss > 0 {
                    result.quoteAlerts.append(QuoteAlert(code: code, name: name, target: stopLoss,
                        direction: .below, enabled: true, lastTriggeredAt: nil))
                }
            }
        }

        let fund = root["fund"] as? [String: Any] ?? [:]
        let funds = fund["hold"] as? [[String: Any]] ?? []
        for row in funds {
            guard let code = string(row["code"]), !code.isEmpty else { continue }
            let cost = number(row["cost"]) ?? 0
            result.holdings.append(Holding(code: code, name: string(row["name"]) ?? code,
                quantity: number(row["shares"]) ?? 0, cost: cost,
                current: number(row["nav"]) ?? cost, kind: .fund))

            let name = string(row["name"]) ?? code
            if string(row["feeMode"]) == "custom", let rate = number(row["feeR"]), (0...100).contains(rate) {
                let bands = [0, 7, 30, 365, 730].map { FundFeeBand(minimumHoldingDays: $0, ratePercent: rate) }
                result.fundFeePolicies.append(FundFeePolicy(code: code, name: name, bands: bands))
            } else if let table = row["feeTable"] as? [String: Any] {
                let days = [0, 7, 30, 365, 730]
                let rates = days.compactMap { number(table[String($0)]) }
                if rates.count == days.count && rates.allSatisfy({ (0...100).contains($0) }) {
                    result.fundFeePolicies.append(FundFeePolicy(code: code, name: name,
                        bands: zip(days, rates).map { FundFeeBand(minimumHoldingDays: $0.0, ratePercent: $0.1) }))
                }
            }
        }
        result.fundNAVHistory = parseFundNAVHistory(root["fundnav"], holdings: funds)

        let cashLog = root["cashlog"] as? [[String: Any]] ?? []
        for row in cashLog {
            guard let type = string(row["type"]), type == "in" || type == "out",
                  let amount = number(row["amt"]), amount.isFinite, amount > 0,
                  let rawDate = string(row["date"]), let date = dateFromDay(String(rawDate.prefix(10))) else { continue }
            let internalFundTransfer = string(row["internal"]) == "fund"
            result.cashFlows.append(CashFlow(date: date, amount: type == "in" ? amount : -amount,
                memo: string(row["note"]) ?? (type == "in" ? "旧版现金转入" : "旧版现金转出"),
                affectsCash: true, external: !internalFundTransfer))
        }

        let snaps = root["snap"] as? [[String: Any]] ?? root["snapshots"] as? [[String: Any]] ?? []
        for row in snaps {
            guard (row["scope"] as? String ?? "all") == "all",
                  let date = string(row["d"]) ?? string(row["date"]) else { continue }
            let cash = number(row["cash"]) ?? result.cash
            let total = number(row["total"]) ?? ((number(row["mv"]) ?? 0) + cash)
            result.snapshots.append(PortfolioSnapshot(date: String(date.prefix(10)), total: total, cash: cash))
        }
        result.snapshots = Array(Dictionary(grouping: result.snapshots, by: \.date).values.compactMap(\.last).sorted { $0.date < $1.date })

        let etfTrades = db["trades"] as? [[String: Any]] ?? []
        for row in etfTrades { appendTrade(row, to: &result, fund: false) }
        let fundTrades = fund["trades"] as? [[String: Any]] ?? []
        for row in fundTrades {
            appendTrade(row, to: &result, fund: true)
            appendFundTransaction(row, to: &result)
        }

        let plans = fund["plans"] as? [[String: Any]] ?? []
        for row in plans { appendDCAPlan(row, fundHoldings: funds, transactions: result.fundTransactions, to: &result) }
        let planEvents = fund["planEvents"] as? [[String: Any]] ?? []
        result.legacyDCAEvents = planEvents.compactMap(legacyDCAEvent)
        result.tradePlans = (db["tradePlans"] as? [[String: Any]] ?? []).compactMap(migrateTradePlan)

        let gridRecords = db["gridTrades"] as? [[String: Any]] ?? []
        for row in gridRecords { appendLegacyGrid(row, to: &result) }
        let bars = parseGridHistory(root["gridhist"])
        appendSettingsArchive("cfg", title: "旧版应用设置", value: root["cfg"], to: &result)
        appendSettingsArchive("profile", title: "旧版个人风格偏好", value: db["profile"], to: &result)
        appendSettingsArchive("tradePlans", title: "旧版交易计划", value: db["tradePlans"], to: &result)
        appendSettingsArchive("hol", title: "旧版自定义休市日", value: root["hol"], to: &result)
        appendSettingsArchive("gridmeta", title: "旧版分时采集状态", value: root["gridmeta"], to: &result)
        appendSettingsArchive("marketTargets", title: "旧版仓位与均线参数", value: root["tgt"], to: &result)

        guard !result.quotes.isEmpty || !result.holdings.isEmpty || !result.snapshots.isEmpty
            || !result.cashFlows.isEmpty || !result.ledger.isEmpty || !result.dayGridPlans.isEmpty
            || !result.fundDCAPlans.isEmpty || !result.legacyDCAEvents.isEmpty
            || !result.legacyGridArchives.isEmpty || !result.fundNAVHistory.isEmpty
            || !result.legacySettingsArchives.isEmpty || !bars.isEmpty || root["cash"] != nil else {
            throw LegacyMigrationError.invalidBackup
        }
        return LegacyMigrationResult(data: result, intradayBars: bars)
    }

    private static func appendTrade(_ row: [String: Any], to data: inout PortfolioData, fund: Bool) {
        if fund && (string(row["status"]) == "pending" || (row["backfill"] as? Bool == true)) { return }
        guard let code = string(row["code"]), let sideText = string(row["side"]) else { return }
        let side: LedgerEntry.Side? = sideText == "buy" ? .buy : (sideText == "sell" ? .sell : nil)
        guard let side else { return }
        let quantity = number(row[fund ? "shares" : "num"]) ?? 0
        let amount = number(row["amt"]) ?? 0
        let price = number(row["price"]) ?? (quantity > 0 ? amount / quantity : 0)
        guard quantity > 0, price > 0 else { return }
        let dateText = string(row["date"]) ?? string(row["settleDate"]) ?? ""
        let date = ISO8601DateFormatter().date(from: dateText) ?? dateFromDay(String(dateText.prefix(10))) ?? .now
        let fee = number(row["fee"]) ?? 0
        let linked = (row["cashSrc"] as? String) == "cash" || (row["cashLinked"] as? Bool == true)
        data.ledger.append(LedgerEntry(date: date, code: code, name: string(row["name"]) ?? code,
            side: side, quantity: quantity, price: price, fee: fee,
            realizedPnL: side == .sell ? (number(row["pnl"]) ?? 0) : 0, linkedCash: linked,
            kind: fund ? .fund : .etf))
    }

    private static func appendFundTransaction(_ row: [String: Any], to data: inout PortfolioData) {
        guard let code = string(row["code"]), !code.isEmpty,
              let rawSide = string(row["side"]), rawSide != "adj" else { return }
        let side: FundTransaction.Side
        switch rawSide {
        case "buy": side = .buy
        case "sell": side = .sell
        case "div": side = .dividend
        default: return
        }
        let request = String((string(row["date"]) ?? "").prefix(10))
        guard request.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return }
        let effective = String((string(row["settleDate"]) ?? request).prefix(10))
        let settled = effective.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? effective : request
        let cashAmount = number(row["cash"]) ?? 0
        let mode = string(row["mode"]) == "cash" || cashAmount > 0
            ? FundTransaction.DividendMode.cash : FundTransaction.DividendMode.reinvest
        let amount = side == .dividend
            ? (cashAmount > 0 ? cashAmount : (number(row["amt"]) ?? cashAmount))
            : (number(row["amt"]) ?? 0)
        let shares = number(row["shares"]) ?? 0
        let status: FundTransaction.Status = string(row["status"]) == "pending" ? .pending : .confirmed
        data.fundTransactions.append(FundTransaction(
            code: code,
            name: string(row["name"]) ?? code,
            side: side,
            requestDate: request,
            effectiveDate: side == .buy ? settled : request,
            quantity: shares,
            nav: number(row["nav"]) ?? 0,
            amount: amount,
            fee: number(row["fee"]) ?? 0,
            realizedPnL: number(row["pnl"]) ?? 0,
            status: status,
            isBackfill: row["backfill"] as? Bool ?? false,
            dividendMode: side == .dividend ? mode : nil,
            linkedCash: string(row["cashSrc"]) == "cash" || (row["cashLinked"] as? Bool == true),
            legacyPlanID: string(row["planId"]),
            legacyPlanDue: string(row["planDue"])
        ))
    }

    private static func appendDCAPlan(_ row: [String: Any], fundHoldings: [[String: Any]],
                                      transactions: [FundTransaction], to data: inout PortfolioData) {
        guard let code = string(row["code"]), !code.isEmpty,
              let amount = number(row["amt"]), amount.isFinite, amount > 0 else { return }
        let cycle = string(row["cycle"]) ?? "month"
        let frequency: FundDCAPlan.Frequency
        switch cycle {
        case "day": frequency = .daily
        case "week": frequency = .weekly
        case "biweek": frequency = .biweekly
        case "month": frequency = .monthly
        default: return
        }
        let startISO = validDay(string(row["start"])) ?? dayString(.now)
        let startWeekday = weekdayFromDay(startISO)
        let weekday = cycle == "week" && (startWeekday == 1 || startWeekday == 7) ? 2 : startWeekday
        let monthDay = min(31, max(1, Int(number(row["day"]) ?? 1)))
        let fundHolding = fundHoldings.first(where: { string($0["code"]) == code })
        let feePercent = fundHolding.flatMap { number($0["feeB"]) } ?? 0.15
        let name = string(row["name"]) ?? fundHolding.flatMap { string($0["name"]) } ?? code
        let legacyID = string(row["id"]) ?? "legacy-\(code)-\(startISO)"
        let processed = transactions.filter { $0.legacyPlanID == legacyID && $0.side == .buy }.map {
            $0.effectiveDate.isEmpty ? ($0.legacyPlanDue ?? $0.requestDate) : $0.effectiveDate
        }
        data.fundDCAPlans.append(FundDCAPlan(
            code: code,
            name: name,
            amount: amount,
            feeRate: min(0.05, max(0, feePercent / 100)),
            frequency: frequency,
            weekday: weekday,
            monthDay: monthDay,
            startDate: startISO,
            enabled: (number(row["paused"]) ?? 0) <= 0,
            processedDates: Array(Set(processed)).sorted()
        ))
    }

    private static func appendLegacyGrid(_ row: [String: Any], to data: inout PortfolioData) {
        guard let code = string(row["code"]), !code.isEmpty else { return }
        let recordID = string(row["id"]) ?? "legacy-\(code)-\(data.legacyGridArchives.count)"
        let capital = number(row["budget"]) ?? 0
        let anchor = number(row["anchor"]) ?? 0
        let lower = number(row["lower"]) ?? 0
        let upper = number(row["upper"]) ?? 0
        let step = number(row["step"]) ?? 0
        let status = string(row["status"]) ?? "unknown"
        let mode = string(row["mode"]) ?? "unknown"
        let horizon = string(row["horizon"]) ?? "intraday"
        let rawJSON = encodeJSON(row)
        data.legacyGridArchives.append(LegacyGridArchive(
            id: recordID, code: code, name: string(row["name"]) ?? code,
            horizon: horizon, status: status, mode: mode,
            capital: capital, quantity: number(row["qty"]) ?? 0,
            anchor: anchor, lower: lower, upper: upper, step: step,
            created: string(row["created"]) ?? "", rawJSON: rawJSON
        ))
        let shadow = row["shadow"] as? [String: Any] ?? [:]
        let shadowQuantity = number(row["qty"]) ?? 0
        let shadowShares = number(shadow["shares"]) ?? shadowQuantity * 3
        let shouldKeepShadow = row["shadow"] != nil || (horizon == "intraday" && status != "closed" && capital > 0 && anchor > 0 && step > 0 && shadowQuantity > 0)
        if shouldKeepShadow {
            let totals = shadow["totals"] as? [String: Any] ?? [:]
            let fills = (shadow["fills"] as? [[String: Any]] ?? []).enumerated().compactMap { index, fill -> LegacyShadowFill? in
                guard let day = string(fill["day"]), let side = string(fill["side"]),
                      let price = number(fill["price"]), price.isFinite, price > 0,
                      let quantity = number(fill["qty"]), quantity.isFinite, quantity > 0 else { return nil }
                return LegacyShadowFill(index: index, day: day, time: string(fill["time"]) ?? "",
                    side: side, price: price, quantity: quantity, fee: number(fill["fee"]) ?? 0,
                    realizedPnL: number(fill["realized"]) ?? 0)
            }
            let daily = shadow["daily"] as? [String: [String: Any]] ?? [:]
            let days = daily.keys.sorted().compactMap { day -> LegacyShadowDay? in
                guard let value = daily[day] else { return nil }
                return LegacyShadowDay(day: day, fills: count(value["fills"]),
                    buys: count(value["buy"]), sells: count(value["sell"]),
                    fees: number(value["fees"]) ?? 0, realizedPnL: number(value["realized"]) ?? 0,
                    startEquity: number(value["startEquity"]) ?? 0, endEquity: number(value["endEquity"]) ?? 0)
            }
            let fillBuys = fills.filter { $0.side == "buy" }.count
            let fillSells = fills.filter { $0.side == "sell" }.count
            let dailyBuys = days.reduce(0) { $0 + $1.buys }
            let dailySells = days.reduce(0) { $0 + $1.sells }
            let scoredFills = fills.filter { $0.side == "sell" }
            data.legacyShadowArchives.append(LegacyShadowArchive(
                id: recordID, code: code, name: string(row["name"]) ?? code,
                capital: number(shadow["capital"]) ?? capital,
                cash: number(shadow["cash"]) ?? (capital - shadowShares * anchor),
                shares: shadowShares, cost: number(shadow["cost"]) ?? anchor,
                lastPrice: number(shadow["lastPrice"]) ?? 0,
                initialPrice: number(shadow["initialPrice"]) ?? anchor,
                initialShares: number(shadow["initialShares"]) ?? shadowShares,
                totalFees: number(totals["fees"]) ?? days.reduce(0) { $0 + $1.fees },
                realizedPnL: number(totals["realized"]) ?? days.reduce(0) { $0 + $1.realizedPnL },
                buys: max(count(totals["buy"]), max(dailyBuys, fillBuys)),
                sells: max(count(totals["sell"]), max(dailySells, fillSells)),
                wins: max(count(totals["wins"]), scoredFills.filter { $0.realizedPnL > 0 }.count),
                scoredSells: max(count(totals["scoredSells"]), scoredFills.count),
                lower: lower, upper: upper, anchor: number(shadow["anchor"]) ?? anchor,
                step: step, quantity: shadowQuantity, eligible: number(shadow["eligible"]) ?? shadowShares,
                t0: row["t0"] as? Bool ?? false,
                active: row["active"] as? Bool == true && status == "active",
                closed: status == "closed", lastTimestamp: string(shadow["lastT"]) ?? "",
                fills: fills, days: days
            ))
        }
        guard horizon == "intraday", capital > 0, anchor > 0, step > 0 else { return }
        let sides = min(anchor - lower, upper - anchor)
        let levels = max(1, min(20, Int(floor(max(0, sides) / step))))
        let active = (row["active"] as? Bool == true) && status == "active"
        data.dayGridPlans.append(DayGridPlan(
            code: code, name: string(row["name"]) ?? code,
            capital: capital, anchor: anchor, stepPercent: step / anchor,
            levelsEachSide: levels, feePerOrder: 0.1, enabled: active,
            legacyRecordID: recordID
        ))
    }

    private static func legacyDCAEvent(_ row: [String: Any]) -> LegacyDCAEventArchive? {
        guard let code = string(row["code"]), !code.isEmpty,
              let due = validDay(string(row["due"])) else { return nil }
        return LegacyDCAEventArchive(
            id: string(row["id"]) ?? "\(code)-\(due)",
            planID: string(row["planId"]) ?? "",
            code: code, name: string(row["name"]) ?? code,
            dueDate: due, amount: number(row["amt"]) ?? 0,
            status: string(row["migrationStatus"]) ?? "未迁入流水",
            rawJSON: encodeJSON(row)
        )
    }

    private static func migrateTradePlan(_ row: [String: Any]) -> TradePlan? {
        guard let code = string(row["code"]), !code.isEmpty,
              let amount = number(row["amount"]), amount.isFinite, amount > 0,
              let price = number(row["price"]), price.isFinite, price > 0 else { return nil }
        let kind: Holding.Kind = string(row["kind"]) == "fund" ? .fund : .etf
        let side: LedgerEntry.Side = string(row["side"]) == "sell" ? .sell : .buy
        let rawStatus = string(row["status"])
        let status: TradePlan.Status = rawStatus == "cancelled" ? .cancelled : (rawStatus == "reviewed" ? .reviewed : .planned)
        let target = number(row["target"])
        let invalid = number(row["invalid"])
        let actualPrice = number(row["actualPrice"])
        let actualAmount = number(row["actualAmount"])
        return TradePlan(id: string(row["id"]) ?? UUID().uuidString, kind: kind, code: code,
            name: string(row["name"]) ?? code, side: side, amount: amount, price: price,
            target: target, invalid: invalid, reason: string(row["reason"]) ?? "",
            trigger: string(row["trigger"]) ?? "", reviewDate: string(row["reviewDate"]) ?? "",
            created: string(row["created"]) ?? "", status: status,
            actualPrice: actualPrice, actualAmount: actualAmount, review: string(row["review"]) ?? "")
    }

    private static func parseGridHistory(_ raw: Any?) -> [IntradayBar] {
        guard let history = raw as? [String: Any] else { return [] }
        var rows: [IntradayBar] = []
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for (code, daily) in history where code.range(of: #"^[A-Za-z0-9._-]{1,16}$"#, options: .regularExpression) != nil {
            guard let days = daily as? [String: Any] else { continue }
            for (day, rawPoints) in days where validDay(day) != nil {
                guard let points = rawPoints as? [[Any]] else { continue }
                for point in points {
                    guard point.count >= 2, let rawTime = point[0] as? String,
                          let price = number(point[1]), price.isFinite, price > 0 else { continue }
                    let timeMatch = rawTime.range(of: #"\d{1,2}:\d{2}(?::\d{2})?"#, options: .regularExpression)
                    let timeText: String
                    if let timeMatch { timeText = String(rawTime[timeMatch]) }
                    else {
                        let digits = rawTime.filter(\.isNumber)
                        guard digits.count >= 4 else { continue }
                        let hhmm = String(digits.suffix(4))
                        timeText = "\(hhmm.prefix(2)):\(hhmm.suffix(2))"
                    }
                    if timeText.count == 5 { formatter.dateFormat = "yyyy-MM-dd HH:mm" }
                    else { formatter.dateFormat = "yyyy-MM-dd HH:mm:ss" }
                    guard let timestamp = formatter.date(from: "\(day) \(timeText)") else { continue }
                    rows.append(IntradayBar(code: code, timestamp: timestamp, price: price, volume: nil, day: day))
                }
            }
        }
        let unique = Dictionary(rows.map { ("\($0.code)|\(Int($0.timestamp.timeIntervalSince1970 / 60))", $0) }, uniquingKeysWith: { _, later in later })
        return unique.values.sorted { $0.timestamp < $1.timestamp }
    }

    private static func parseFundNAVHistory(_ raw: Any?, holdings: [[String: Any]]) -> [FundNAVPoint] {
        var points: [FundNAVPoint] = []
        if let history = raw as? [String: Any] {
            for (code, value) in history where code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil {
                let rows: [[String: Any]]
                if let array = value as? [[String: Any]] { rows = array }
                else if let object = value as? [String: Any], let array = object["navHistory"] as? [[String: Any]] { rows = array }
                else { continue }
                for row in rows {
                    guard let date = validDay(string(row["date"])),
                          let nav = number(row["nav"]), nav.isFinite, nav > 0 else { continue }
                    points.append(FundNAVPoint(code: code, date: date, nav: nav))
                }
            }
        }
        for holding in holdings {
            guard let code = string(holding["code"]), let date = validDay(string(holding["navDate"])),
                  let nav = number(holding["nav"]), nav.isFinite, nav > 0,
                  !points.contains(where: { $0.code == code && $0.date == date }) else { continue }
            points.append(FundNAVPoint(code: code, date: date, nav: nav))
        }
        let unique = Dictionary(points.map { ("\($0.code)|\($0.date)", $0) }, uniquingKeysWith: { _, latest in latest })
        return unique.values.sorted { $0.code == $1.code ? $0.date < $1.date : $0.code < $1.code }
    }

    private static func validDay(_ value: String?) -> String? {
        guard let value, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: value) == nil ? nil : value
    }

    private static func weekdayFromDay(_ day: String) -> Int {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day) else { return 2 }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.component(.weekday, from: date)
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func encodeJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func appendSettingsArchive(_ id: String, title: String, value: Any?, to data: inout PortfolioData) {
        guard let value, !(value is NSNull) else { return }
        let encoded = encodeJSON(value)
        guard encoded != "{}" else { return }
        data.legacySettingsArchives.append(LegacySettingsArchive(id: id, title: title, rawJSON: encoded))
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
    private static func count(_ value: Any?) -> Int {
        guard let value = number(value), value.isFinite else { return 0 }
        return Int(min(1_000_000, max(0, value)))
    }
    private static func dateFromDay(_ value: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: value)
    }
}
