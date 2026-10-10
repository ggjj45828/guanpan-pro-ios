import Foundation

private struct FundOpenLot {
    var date: String
    var shares: Double
}

@MainActor
extension PortfolioStore {
    func saveFundFeePolicy(code: String, name: String, bands: [FundFeeBand], sellMode: FundSellMode = .fifo) throws {
        let sorted = bands.sorted { $0.minimumHoldingDays < $1.minimumHoldingDays }
        guard !code.isEmpty, (1...10).contains(sorted.count), sorted.first?.minimumHoldingDays == 0,
              Set(sorted.map(\.minimumHoldingDays)).count == sorted.count,
              sorted.allSatisfy({ $0.minimumHoldingDays >= 0 && $0.minimumHoldingDays <= 10_000
                  && $0.ratePercent.isFinite && (0...100).contains($0.ratePercent) }) else {
            throw StoreError.invalidFundFeePolicy
        }
        let policy = FundFeePolicy(code: code, name: name, bands: sorted, sellMode: sellMode)
        if let index = data.fundFeePolicies.firstIndex(where: { $0.code == code }) { data.fundFeePolicies[index] = policy }
        else { data.fundFeePolicies.append(policy) }
        save()
    }

    func removeFundFeePolicy(code: String) {
        data.fundFeePolicies.removeAll { $0.code == code }
        save()
    }

    /// Estimates a redemption fee only when both the fund's own fee table and
    /// the purchase/reinvestment history fully explain current units.
    /// Missing lots or rates return nil instead of silently assuming zero.
    func estimateFundRedemptionFee(code: String, shares requested: Double, nav: Double, on date: Date) -> FundFeeEstimate? {
        guard requested.isFinite, requested > 0, nav.isFinite, nav > 0,
              let policy = data.fundFeePolicies.first(where: { $0.code == code }),
              let holding = data.holdings.first(where: { $0.code == code && $0.kind == .fund }) else { return nil }
        let todayLots = fundLots(code: code, through: "9999-12-31")
        guard abs(todayLots.reduce(0) { $0 + $1.shares } - holding.quantity) <= 0.02 else { return nil }
        let day = fundDay(date)
        var lots = fundLots(code: code, through: day)
        guard requested <= lots.reduce(0, { $0 + $1.shares }) + 1e-8 else { return nil }
        switch policy.sellMode ?? .fifo {
        case .fifo: break
        case .lifo: lots.sort { $0.date > $1.date }
        case .lowestFee:
            lots.sort { lhs, rhs in
                let lhsDays = fundDays(from: lhs.date, to: day) ?? 0
                let rhsDays = fundDays(from: rhs.date, to: day) ?? 0
                let lhsRate = policy.bands.last(where: { $0.minimumHoldingDays <= lhsDays })?.ratePercent ?? .infinity
                let rhsRate = policy.bands.last(where: { $0.minimumHoldingDays <= rhsDays })?.ratePercent ?? .infinity
                return lhsRate == rhsRate ? lhs.date < rhs.date : lhsRate < rhsRate
            }
        }
        var remaining = requested
        var parts: [(Int, Double, Double, Double)] = []
        var allocations: [FundLotRedemption] = []
        for index in lots.indices where remaining > 1e-8 {
            let take = min(lots[index].shares, remaining)
            guard take > 0, let days = fundDays(from: lots[index].date, to: day),
                  let band = policy.bands.last(where: { $0.minimumHoldingDays <= days }) else { return nil }
            let fee = take * nav * band.ratePercent / 100
            guard fee.isFinite else { return nil }
            parts.append((days, take, band.ratePercent, fee))
            allocations.append(FundLotRedemption(purchaseDate: lots[index].date, shares: take))
            lots[index].shares -= take
            remaining -= take
        }
        guard remaining <= 1e-6, !parts.isEmpty else { return nil }
        return FundFeeEstimate(total: parts.reduce(0) { $0 + $1.3 },
            parts: parts.enumerated().map { index, part in
                (purchaseDate: allocations[index].purchaseDate, days: part.0, shares: part.1,
                    ratePercent: part.2, fee: part.3)
            }, redemptionLots: allocations)
    }

    private func fundLots(code: String, through day: String) -> [FundOpenLot] {
        let events = data.fundTransactions.filter { $0.code == code && $0.status == .confirmed && $0.effectiveDate <= day }
            .sorted {
                if $0.effectiveDate != $1.effectiveDate { return $0.effectiveDate < $1.effectiveDate }
                return fundFeeEventOrder($0.side) < fundFeeEventOrder($1.side)
            }
        var lots: [FundOpenLot] = []
        for event in events {
            switch event.side {
            case .buy:
                if event.quantity > 0 { lots.append(FundOpenLot(date: event.effectiveDate, shares: event.quantity)) }
            case .dividend:
                if event.dividendMode == .reinvest && event.quantity > 0 {
                    lots.append(FundOpenLot(date: event.effectiveDate, shares: event.quantity))
                }
            case .sell:
                var need = event.quantity
                if let allocations = event.redemptionLots, !allocations.isEmpty {
                    for allocation in allocations where allocation.shares > 0 && allocation.shares.isFinite {
                        guard let index = lots.firstIndex(where: { $0.date == allocation.purchaseDate }),
                              allocation.shares <= lots[index].shares + 1e-8 else { return [] }
                        let take = min(lots[index].shares, allocation.shares)
                        lots[index].shares -= take
                        need -= take
                    }
                    if need < -0.02 { return [] }
                } else {
                    for index in lots.indices where need > 1e-8 {
                        let take = min(lots[index].shares, need)
                        lots[index].shares -= take
                        need -= take
                    }
                }
                lots.removeAll { $0.shares <= 1e-8 }
                // Inconsistent history is not a basis for a fee estimate.
                if need > 0.02 { return [] }
            }
        }
        return lots
    }

    private func fundFeeEventOrder(_ side: FundTransaction.Side) -> Int {
        switch side { case .buy, .dividend: return 0; case .sell: return 1 }
    }

    private func fundDay(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func fundDays(from start: String, to end: String) -> Int? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        guard let a = formatter.date(from: start), let b = formatter.date(from: end), b >= a else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.dateComponents([.day], from: a, to: b).day
    }
}
