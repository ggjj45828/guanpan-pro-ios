import Foundation

@MainActor
extension PortfolioStore {
    func setLegacyShadowActive(_ archive: LegacyShadowArchive, active: Bool) {
        guard let index = data.legacyShadowArchives.firstIndex(where: { $0.id == archive.id }),
              !data.legacyShadowArchives[index].closed else { return }
        data.legacyShadowArchives[index].active = active
        // Reset the crossing baseline on resume so a paused interval cannot create
        // a synthetic fill when the next quote arrives.
        data.legacyShadowArchives[index].lastPrice = 0
        data.legacyShadowArchives[index].lastTimestamp = ""
        save()
    }

    func advanceLegacyShadowSimulations(_ quotes: [(String, Double, Date)]) {
        let byCode = Dictionary(quotes.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { _, latest in latest })
        let dayFormatter = DateFormatter(); dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter(); timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); timeFormatter.dateFormat = "HH:mm:ss"

        for index in data.legacyShadowArchives.indices {
            var shadow = data.legacyShadowArchives[index]
            guard !shadow.closed, let (price, timestamp) = byCode[shadow.code],
                  price.isFinite, price > 0 else { continue }
            let day = dayFormatter.string(from: timestamp)
            let time = timeFormatter.string(from: timestamp)
            let stamp = "\(day) \(time)"
            let previous = shadow.lastPrice > 0 ? shadow.lastPrice : price
            let dayIndex: Int
            if let found = shadow.days.firstIndex(where: { $0.day == day }) {
                dayIndex = found
            } else {
                shadow.days.append(LegacyShadowDay(day: day, fills: 0, buys: 0, sells: 0,
                    fees: 0, realizedPnL: 0, startEquity: shadow.cash + shadow.shares * previous,
                    endEquity: shadow.cash + shadow.shares * previous))
                dayIndex = shadow.days.count - 1
            }

            if shadow.lastTimestamp != stamp && shadow.lastPrice > 0 && shadow.active && shadow.step > 0 && shadow.quantity > 0 {
                let etf = Self.isGridETF(shadow.code)
                let tick = etf ? 0.001 : 0.01
                let decimals = etf ? 3.0 : 2.0
                let scale = pow(10.0, decimals)
                let buyLevel = ((shadow.anchor - shadow.step) * scale).rounded() / scale
                let sellLevel = ((shadow.anchor + shadow.step) * scale).rounded() / scale
                if previous > buyLevel + tick / 2, price <= buyLevel - tick / 2, buyLevel >= shadow.lower {
                    let amount = buyLevel * shadow.quantity
                    let fee = Self.legacyShadowFee(code: shadow.code, side: "buy", amount: amount)
                    let slippage = tick * shadow.quantity
                    let debit = amount + fee + slippage
                    if shadow.cash >= debit {
                        shadow.cost = ((shadow.shares * (shadow.cost > 0 ? shadow.cost : buyLevel)) + amount + fee + slippage) / (shadow.shares + shadow.quantity)
                        shadow.cash -= debit; shadow.shares += shadow.quantity
                        if shadow.t0 { shadow.eligible += shadow.quantity }
                        shadow.totalFees += fee + slippage; shadow.buys += 1
                        shadow.anchor = buyLevel
                        shadow.days[dayIndex].buys += 1; shadow.days[dayIndex].fills += 1
                        shadow.days[dayIndex].fees += fee + slippage
                        shadow.fills.append(LegacyShadowFill(index: Int(timestamp.timeIntervalSince1970), day: day,
                            time: time, side: "buy", price: buyLevel, quantity: shadow.quantity,
                            fee: fee + slippage, realizedPnL: 0))
                    }
                } else if previous < sellLevel - tick / 2, price >= sellLevel + tick / 2,
                          sellLevel <= shadow.upper, shadow.eligible >= shadow.quantity {
                    let amount = sellLevel * shadow.quantity
                    let fee = Self.legacyShadowFee(code: shadow.code, side: "sell", amount: amount)
                    let slippage = tick * shadow.quantity
                    let realized = (sellLevel - (shadow.cost > 0 ? shadow.cost : sellLevel)) * shadow.quantity - fee - slippage
                    shadow.cash += amount - fee - slippage; shadow.shares -= shadow.quantity
                    shadow.eligible -= shadow.quantity
                    if shadow.shares <= 0 { shadow.shares = 0; shadow.cost = 0 }
                    shadow.totalFees += fee + slippage; shadow.realizedPnL += realized
                    shadow.sells += 1; shadow.scoredSells += 1
                    if realized > 0 { shadow.wins += 1 }
                    shadow.anchor = sellLevel
                    shadow.days[dayIndex].sells += 1; shadow.days[dayIndex].fills += 1
                    shadow.days[dayIndex].fees += fee + slippage
                    shadow.days[dayIndex].realizedPnL += realized
                    shadow.fills.append(LegacyShadowFill(index: Int(timestamp.timeIntervalSince1970), day: day,
                        time: time, side: "sell", price: sellLevel, quantity: shadow.quantity,
                        fee: fee + slippage, realizedPnL: realized))
                }
            }

            shadow.lastPrice = price
            shadow.lastTimestamp = stamp
            shadow.days[dayIndex].endEquity = shadow.cash + shadow.shares * price
            shadow.days.sort { $0.day < $1.day }
            if shadow.days.count > 60 { shadow.days.removeFirst(shadow.days.count - 60) }
            if shadow.fills.count > 300 { shadow.fills.removeFirst(shadow.fills.count - 300) }
            data.legacyShadowArchives[index] = shadow
        }
    }

    private static func isGridETF(_ code: String) -> Bool {
        let digits = code.lowercased().replacingOccurrences(of: "^(sh|sz|bj)", with: "", options: .regularExpression)
        return digits.range(of: "^(51|56|58|159|150|16|18)|^(15|16|18)\\d{4}$", options: .regularExpression) != nil
    }

    private static func legacyShadowFee(code: String, side: String, amount: Double) -> Double {
        if isGridETF(code) { return 0.10 }
        let commission = max(5, amount * 0.000086)
        return commission + (side == "sell" ? amount * 0.0005 : 0)
    }

    var gridTradingDays: [String] {
        Array(Set(intradayBars.map(\.day))).sorted(by: >)
    }

    var gridBarCount: Int { intradayBars.count }

    func saveGridPlan(code: String, name: String, capital: Double, anchor: Double,
                      stepPercent: Double, levels: Int, feePerOrder: Double) throws {
        guard !code.isEmpty, capital.isFinite, capital > 0, anchor.isFinite, anchor > 0,
              stepPercent.isFinite, (0.05...10).contains(stepPercent), (1...20).contains(levels),
              feePerOrder.isFinite, feePerOrder >= 0, feePerOrder <= 100 else {
            throw GridError.invalidPlan
        }
        if let index = data.dayGridPlans.firstIndex(where: { $0.code == code }) {
            data.dayGridPlans[index].name = name
            data.dayGridPlans[index].capital = capital
            data.dayGridPlans[index].anchor = anchor
            data.dayGridPlans[index].stepPercent = stepPercent / 100
            data.dayGridPlans[index].levelsEachSide = levels
            data.dayGridPlans[index].feePerOrder = feePerOrder
        } else {
            data.dayGridPlans.append(DayGridPlan(code: code, name: name, capital: capital, anchor: anchor,
                stepPercent: stepPercent / 100, levelsEachSide: levels, feePerOrder: feePerOrder, enabled: true))
        }
        save()
    }

    func removeGridPlan(_ plan: DayGridPlan) {
        data.dayGridPlans.removeAll { $0.id == plan.id }
        save()
    }

    /// Transparent rule-based sizing helper. It is deliberately not labelled AI:
    /// it estimates a spacing from saved intraday ranges and refuses sparse data.
    func gridRecommendation(code: String, capital: Double, feePerOrder: Double) -> GridRecommendation? {
        guard capital.isFinite, capital > 0, feePerOrder.isFinite, feePerOrder >= 0 else { return nil }
        let grouped = Dictionary(grouping: intradayBars.filter { $0.code == code }, by: \.day)
        let reliableDays: [[IntradayBar]] = grouped.values.compactMap { dayBars in
            let sorted = dayBars.sorted { $0.timestamp < $1.timestamp }
            guard sorted.count >= 168 else { return nil }
            let largestGap = zip(sorted, sorted.dropFirst()).map { $0.1.timestamp.timeIntervalSince($0.0.timestamp) }.max() ?? .infinity
            return largestGap <= 10 * 60 ? sorted : nil
        }.sorted { ($0.last?.timestamp ?? .distantPast) < ($1.last?.timestamp ?? .distantPast) }.suffix(20).map { $0 }
        guard reliableDays.count >= 3, let latestDay = reliableDays.last, let anchor = latestDay.last?.price,
              anchor.isFinite, anchor > 0 else { return nil }
        let ranges = reliableDays.compactMap { day -> Double? in
            let prices = day.map(\.price).filter { $0.isFinite && $0 > 0 }
            guard let low = prices.min(), let high = prices.max(), low > 0 else { return nil }
            return (high - low) / ((high + low) / 2)
        }.sorted()
        guard let medianRange = ranges.dropFirst(max(0, (ranges.count - 1) / 2)).first, medianRange.isFinite, medianRange > 0 else { return nil }
        let feeFloor = 2 * feePerOrder / (anchor * 100) + 0.001 // fees plus a modest friction buffer
        let stepFraction = max(0.0005, min(0.01, max(medianRange * 0.25, feeFloor)))
        guard stepFraction <= medianRange * 0.8 else { return nil }
        let lotCost = anchor * 100 + feePerOrder
        let maximumLevels = Int(floor((capital / lotCost - 2) / 2))
        guard maximumLevels >= 1 else { return nil }
        let levels = min(5, maximumLevels)
        let averageCoverage = reliableDays.map { min(1, Double($0.count) / 240) }.reduce(0, +) / Double(reliableDays.count)
        let dayFactor = min(1, Double(reliableDays.count) / 10)
        let feeRatio = min(1, feeFloor / stepFraction)
        let score = max(0, min(100, Int((averageCoverage * 55 + dayFactor * 30 + (1 - feeRatio) * 15).rounded())))
        return GridRecommendation(anchor: anchor, stepPercent: stepFraction * 100, levels: levels, score: score,
            daysUsed: reliableDays.count, medianDailyRangePercent: medianRange * 100,
            summary: "基于最近 \(reliableDays.count) 个覆盖合格的交易日；日内振幅中位数 \(String(format: "%.2f", medianRange * 100))%。分数只代表数据覆盖、样本量和费用空间，不预测收益。")
    }

    /// Import minute CSV using either separate date/time columns or a full timestamp column.
    /// Duplicate code+minute observations are replaced by the imported row.
    func importIntradayCSV(_ dataBytes: Data, fallbackCode: String) throws -> Int {
        guard let text = String(data: dataBytes, encoding: .utf8) else { throw GridError.invalidCSV }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > 1 else { throw GridError.invalidCSV }
        let header = lines[0].replacingOccurrences(of: "\u{FEFF}", with: "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        let codeColumn = header.firstIndex(of: "code")
        let dateColumn = header.firstIndex(where: { ["date", "日期"].contains($0) })
        let timeColumn = header.firstIndex(where: { ["time", "时间"].contains($0) })
        let stampColumn = header.firstIndex(where: { ["timestamp", "datetime", "date_time", "时间戳"].contains($0) })
        let priceColumn = header.firstIndex(where: { ["price", "close", "收盘", "收盘价", "价格"].contains($0) })
        let volumeColumn = header.firstIndex(of: "volume")
        guard let priceColumn,
              (codeColumn != nil || !fallbackCode.isEmpty),
              (dateColumn != nil && timeColumn != nil) || stampColumn != nil || (dateColumn == nil && timeColumn != nil) else {
            throw GridError.invalidCSV
        }
        var parsed: [IntradayBar] = []
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let dateFormats = ["yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"]
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = tz
        let dayFormatter = DateFormatter(); dayFormatter.locale = Locale(identifier: "en_US_POSIX"); dayFormatter.timeZone = tz; dayFormatter.dateFormat = "yyyy-MM-dd"
        for raw in lines.dropFirst() {
            let cols = raw.split(separator: ",", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            guard cols.indices.contains(priceColumn), let price = Double(cols[priceColumn]), price.isFinite, price > 0 else { continue }
            let code = codeColumn.flatMap { cols.indices.contains($0) ? cols[$0] : nil } ?? fallbackCode
            let rawStamp: String
            if let dateColumn, let timeColumn {
                guard cols.indices.contains(dateColumn), cols.indices.contains(timeColumn) else { continue }
                rawStamp = "\(cols[dateColumn]) \(cols[timeColumn])"
            } else if let stampColumn {
                guard cols.indices.contains(stampColumn) else { continue }
                rawStamp = cols[stampColumn]
            } else if let timeColumn {
                guard cols.indices.contains(timeColumn) else { continue }
                rawStamp = cols[timeColumn]
            } else { continue }
            var timestamp: Date?
            for format in dateFormats {
                formatter.dateFormat = format
                timestamp = formatter.date(from: rawStamp)
                if timestamp != nil { break }
            }
            guard let timestamp else { continue }
            let volumeText = volumeColumn.flatMap { cols.indices.contains($0) ? cols[$0] : nil }
            let volume: Double?
            if let volumeText, let value = Double(volumeText), value.isFinite, value >= 0 { volume = value }
            else { volume = nil }
            parsed.append(IntradayBar(code: code.isEmpty ? fallbackCode : code, timestamp: timestamp,
                price: price, volume: volume, day: dayFormatter.string(from: timestamp)))
        }
        guard !parsed.isEmpty else { throw GridError.invalidCSV }
        let minuteKeys = Set(parsed.map { "\($0.code)-\(Int($0.timestamp.timeIntervalSince1970 / 60))" })
        intradayBars.removeAll { minuteKeys.contains("\($0.code)-\(Int($0.timestamp.timeIntervalSince1970 / 60))") }
        let minuteUnique = Dictionary(parsed.map { ("\($0.code)-\(Int($0.timestamp.timeIntervalSince1970 / 60))", $0) }, uniquingKeysWith: { _, latest in latest })
        intradayBars.append(contentsOf: minuteUnique.values)
        saveIntradayBars()
        return minuteUnique.count
    }

    /// Store only points observed while the app is foregrounded. The caller
    /// must provide a validated live quote; no synthetic bars are generated.
    func captureMinuteQuote(code: String, price: Double, at time: Date = .now) {
        captureMinuteQuotes([(code, price)], at: time)
    }

    func captureMinuteQuotes(_ quotes: [(String, Double)], at time: Date = .now) {
        guard !quotes.isEmpty else { return }
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = tz; formatter.dateFormat = "yyyy-MM-dd"
        let minute = Int(time.timeIntervalSince1970 / 60)
        var changed = false
        var added: [IntradayBar] = []
        for (code, price) in quotes where !code.isEmpty && price.isFinite && price > 0 {
            guard !intradayBars.contains(where: { $0.code == code && Int($0.timestamp.timeIntervalSince1970 / 60) == minute }) else { continue }
            let bar = IntradayBar(code: code, timestamp: time, price: price, volume: nil, day: formatter.string(from: time))
            intradayBars.append(bar)
            added.append(bar)
            changed = true
        }
        guard changed else { return }
        appendIntradayBars(added)
    }

    func replayGrid(plan: DayGridPlan, day: String) -> GridReplayResult? {
        let bars = intradayBars.filter { $0.code == plan.code && $0.day == day }.sorted { $0.timestamp < $1.timestamp }
        guard bars.count >= 10, let first = bars.first, let last = bars.last else { return nil }
        let expected = 240.0
        let coverage = min(1, Double(bars.count) / expected)
        let largestGap = zip(bars, bars.dropFirst()).map { $0.1.timestamp.timeIntervalSince($0.0.timestamp) }.max() ?? .infinity
        guard coverage >= 0.70, largestGap <= 10 * 60 else { return nil }
        let levels = max(1, plan.levelsEachSide)
        let lot = 100.0
        let perRungBudget = plan.capital / Double(levels * 2 + 2)
        let sharesPerRung = floor(perRungBudget / (plan.anchor * lot)) * lot
        guard sharesPerRung >= lot else { return GridReplayResult(code: plan.code, day: day, fills: 0, buyCount: 0, sellCount: 0, startCapital: plan.capital, endingValue: plan.capital, fees: 0, coverage: coverage) }

        // Start with half in inventory and half in cash, matching an already-held
        // ETF plus reserve cash. This is a self-contained simulation account.
        var shares = floor((plan.capital * 0.5 / first.price) / lot) * lot
        var cash = plan.capital - shares * first.price
        var fees = 0.0, buys = 0, sells = 0
        var previous = first.price
        for bar in bars.dropFirst() {
            let current = bar.price
            for level in 1...levels {
                let buyLevel = plan.anchor * pow(1 - plan.stepPercent, Double(level))
                if previous > buyLevel && current <= buyLevel && cash >= sharesPerRung * current + plan.feePerOrder {
                    cash -= sharesPerRung * current + plan.feePerOrder; shares += sharesPerRung; fees += plan.feePerOrder; buys += 1
                }
                let sellLevel = plan.anchor * pow(1 + plan.stepPercent, Double(level))
                if previous < sellLevel && current >= sellLevel && shares >= sharesPerRung {
                    cash += sharesPerRung * current - plan.feePerOrder; shares -= sharesPerRung; fees += plan.feePerOrder; sells += 1
                }
            }
            previous = current
        }
        return GridReplayResult(code: plan.code, day: day, fills: buys + sells, buyCount: buys,
            sellCount: sells, startCapital: plan.capital, endingValue: cash + shares * last.price,
            fees: fees, coverage: coverage)
    }
}

enum GridError: LocalizedError {
    case invalidPlan, invalidCSV
    var errorDescription: String? {
        switch self {
        case .invalidPlan: return "请检查代码、资金、锚点、网格间距、档位和单笔费用。"
        case .invalidCSV: return "CSV无法解析。请提供代码、完整日期时间、价格列；支持 date,time 或 timestamp 表头。"
        }
    }
}
