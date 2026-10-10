import Foundation

struct Quote: Codable, Identifiable {
    var id: String { code }
    var code: String
    var name: String
    var price: Double
    var changePct: Double
    var updatedAt: Date?
}

struct QuoteAlert: Codable, Identifiable {
    enum Direction: String, Codable { case above, below }
    var id: UUID = UUID()
    var code: String
    var name: String
    var target: Double
    var direction: Direction
    var enabled: Bool
    var lastTriggeredAt: Date?
}

struct Holding: Codable, Identifiable {
    var id: String { "\(kind.rawValue)-\(code)" }
    var code: String
    var name: String
    var quantity: Double
    var cost: Double
    var current: Double
    var kind: Kind

    enum Kind: String, Codable { case etf, fund }
    var marketValue: Double { quantity * current }
    var pnl: Double { quantity * (current - cost) }
}

struct AllocationTarget: Codable, Identifiable {
    var id: String { "\(kind.rawValue)-\(code)" }
    var code: String
    var name: String
    var kind: Holding.Kind
    var targetPercent: Double
}

enum AppAppearance: String, Codable { case system, light, dark }

struct InvestmentProfile: Codable {
    var style = "swing"
    var risk = "bal"
    var maxPositionPercent = 35.0
    var horizon = "1-3个月"
    var premiumSensitive = true
    var preference = ""
    var avoid = ""
    var method = ""
    var goal = ""

    private enum CodingKeys: String, CodingKey { case style, risk, maxPositionPercent, horizon, premiumSensitive, preference, avoid, method, goal }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "swing"
        risk = try c.decodeIfPresent(String.self, forKey: .risk) ?? "bal"
        let decodedMaxPosition = try c.decodeIfPresent(Double.self, forKey: .maxPositionPercent)
        maxPositionPercent = decodedMaxPosition ?? 35
        horizon = try c.decodeIfPresent(String.self, forKey: .horizon) ?? "1-3个月"
        let decodedPremium = try c.decodeIfPresent(Bool.self, forKey: .premiumSensitive)
        premiumSensitive = decodedPremium ?? true
        preference = try c.decodeIfPresent(String.self, forKey: .preference) ?? ""
        avoid = try c.decodeIfPresent(String.self, forKey: .avoid) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
    }
}

struct TradePlan: Codable, Identifiable {
    enum Status: String, Codable { case planned, reviewed, cancelled }
    var id: String
    var kind: Holding.Kind
    var code: String
    var name: String
    var side: LedgerEntry.Side
    var amount: Double
    var price: Double
    var target: Double?
    var invalid: Double?
    var reason: String
    var trigger: String
    var reviewDate: String
    var created: String
    var status: Status
    var actualPrice: Double?
    var actualAmount: Double?
    var review: String
}

struct PortfolioSnapshot: Codable, Identifiable {
    var id: String { date }
    var date: String
    var total: Double
    var cash: Double
    var recordedAt: Date? = nil
}

struct CashFlow: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = .now
    /// Positive is money added to the tracked account; negative is withdrawn.
    var amount: Double
    var memo: String
    /// False denotes an external investment booked into holdings without changing reference cash.
    var affectsCash: Bool? = true
    /// Whether the flow is external to the tracked portfolio for return adjustment.
    /// Nil preserves the legacy behavior and is interpreted as true.
    var external: Bool? = true
}

struct FundNAVPoint: Codable, Identifiable {
    var id: String { "\(code)-\(date)" }
    var code: String
    var date: String
    var nav: Double
}

struct FundTransaction: Codable, Identifiable {
    enum Side: String, Codable { case buy, sell, dividend }
    enum Status: String, Codable { case confirmed, pending }
    enum DividendMode: String, Codable { case cash, reinvest }

    var id: UUID = UUID()
    var code: String
    var name: String
    var side: Side
    var requestDate: String
    var effectiveDate: String
    var quantity: Double
    var nav: Double
    var amount: Double
    var fee: Double
    var realizedPnL: Double
    var status: Status
    var isBackfill: Bool
    var dividendMode: DividendMode?
    var linkedCash: Bool
    var isAutomaticDCA: Bool? = nil
    var dcaPlanID: UUID? = nil
    var legacyPlanID: String? = nil
    var legacyPlanDue: String? = nil
    var redemptionLots: [FundLotRedemption]? = nil
}

struct FundFeeBand: Codable, Identifiable {
    var id: UUID = UUID()
    var minimumHoldingDays: Int
    var ratePercent: Double
}

struct FundFeePolicy: Codable, Identifiable {
    var id: String { code }
    var code: String
    var name: String
    var bands: [FundFeeBand]
    // Nil means FIFO for policies saved by older native versions.
    var sellMode: FundSellMode? = nil
}

enum FundSellMode: String, Codable, CaseIterable, Identifiable {
    case fifo, lifo, lowestFee
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fifo: return "先进先出"
        case .lifo: return "后进先出"
        case .lowestFee: return "优先低费率"
        }
    }
}

struct FundLotRedemption: Codable {
    var purchaseDate: String
    var shares: Double
}

struct FundFeeEstimate {
    var total: Double
    var parts: [(purchaseDate: String, days: Int, shares: Double, ratePercent: Double, fee: Double)]
    var redemptionLots: [FundLotRedemption]
}

struct FundDCAPlan: Codable, Identifiable {
    enum Frequency: String, Codable { case daily, weekly, biweekly, monthly }
    var id: UUID = UUID()
    var code: String
    var name: String
    var amount: Double
    /// Fraction of the planned cash amount; nil on an older native backup means 0.15%.
    var feeRate: Double? = nil
    var frequency: Frequency
    /// Calendar weekday: Sunday = 1 ... Saturday = 7.
    var weekday: Int
    /// Day of month, limited to 1...28 so the date always exists.
    var monthDay: Int
    var startDate: String
    var enabled: Bool
    var processedDates: [String]
}

struct FundDailyPerformance: Identifiable {
    var id: String { date }
    var date: String
    var profit: Double
    var baseValue: Double
    var fundCount: Int
}

/// Locally captured or imported one-minute observations. These are market data,
/// never portfolio transactions. `day` uses Asia/Shanghai calendar dates.
struct IntradayBar: Codable, Identifiable {
    var id: String { "\(code)-\(timestamp.timeIntervalSince1970)" }
    var code: String
    var timestamp: Date
    var price: Double
    var volume: Double?
    var day: String
}

/// Tencent daily adjusted K-line observation. Historical market data only.
struct DailyBar: Codable, Identifiable {
    var id: String { "\(code)-\(date)" }
    var code: String
    var date: String
    var open: Double
    var close: Double
    var high: Double
    var low: Double
    var volume: Double
}

struct DayGridPlan: Codable, Identifiable {
    var id: UUID = UUID()
    var code: String
    var name: String
    var capital: Double
    var anchor: Double
    var stepPercent: Double
    var levelsEachSide: Int
    var feePerOrder: Double
    var enabled: Bool
    var legacyRecordID: String? = nil
}

struct LegacyGridArchive: Codable, Identifiable {
    var id: String
    var code: String
    var name: String
    var horizon: String
    var status: String
    var mode: String
    var capital: Double
    var quantity: Double
    var anchor: Double
    var lower: Double
    var upper: Double
    var step: Double
    var created: String
    var rawJSON: String
}

struct LegacyShadowFill: Codable, Identifiable {
    var id: String { "\(day)-\(time)-\(index)" }
    var index: Int
    var day: String
    var time: String
    var side: String
    var price: Double
    var quantity: Double
    var fee: Double
    var realizedPnL: Double
}

struct LegacyShadowDay: Codable, Identifiable {
    var id: String { day }
    var day: String
    var fills: Int
    var buys: Int
    var sells: Int
    var fees: Double
    var realizedPnL: Double
    var startEquity: Double
    var endEquity: Double
}

struct LegacyShadowArchive: Codable, Identifiable {
    var id: String
    var code: String
    var name: String
    var capital: Double
    var cash: Double
    var shares: Double
    var cost: Double
    var lastPrice: Double
    var initialPrice: Double
    var initialShares: Double
    var totalFees: Double
    var realizedPnL: Double
    var buys: Int
    var sells: Int
    var wins: Int
    var scoredSells: Int
    var lower: Double
    var upper: Double
    var anchor: Double
    var step: Double
    var quantity: Double
    var eligible: Double
    var t0: Bool
    var active: Bool
    var closed: Bool
    var lastTimestamp: String
    var fills: [LegacyShadowFill]
    var days: [LegacyShadowDay]

    private enum CodingKeys: String, CodingKey {
        case id, code, name, capital, cash, shares, cost, lastPrice, initialPrice, initialShares, totalFees, realizedPnL
        case buys, sells, wins, scoredSells, lower, upper, anchor, step, quantity, eligible, t0, active, closed, lastTimestamp, fills, days
    }

    init(id: String, code: String, name: String, capital: Double, cash: Double, shares: Double, cost: Double,
         lastPrice: Double, initialPrice: Double, initialShares: Double, totalFees: Double, realizedPnL: Double,
         buys: Int, sells: Int, wins: Int, scoredSells: Int, lower: Double, upper: Double, anchor: Double,
         step: Double, quantity: Double, eligible: Double, t0: Bool, active: Bool, closed: Bool,
         lastTimestamp: String, fills: [LegacyShadowFill], days: [LegacyShadowDay]) {
        self.id = id; self.code = code; self.name = name; self.capital = capital; self.cash = cash
        self.shares = shares; self.cost = cost; self.lastPrice = lastPrice; self.initialPrice = initialPrice
        self.initialShares = initialShares; self.totalFees = totalFees; self.realizedPnL = realizedPnL
        self.buys = buys; self.sells = sells; self.wins = wins; self.scoredSells = scoredSells
        self.lower = lower; self.upper = upper; self.anchor = anchor; self.step = step; self.quantity = quantity
        self.eligible = eligible; self.t0 = t0; self.active = active; self.closed = closed
        self.lastTimestamp = lastTimestamp; self.fills = fills; self.days = days
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let decodedCode = try c.decode(String.self, forKey: .code)
        code = decodedCode
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? decodedCode
        capital = try c.decodeIfPresent(Double.self, forKey: .capital) ?? 0
        cash = try c.decodeIfPresent(Double.self, forKey: .cash) ?? 0
        let decodedShares = try c.decodeIfPresent(Double.self, forKey: .shares) ?? 0
        shares = decodedShares
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        lastPrice = try c.decodeIfPresent(Double.self, forKey: .lastPrice) ?? 0
        initialPrice = try c.decodeIfPresent(Double.self, forKey: .initialPrice) ?? 0
        initialShares = try c.decodeIfPresent(Double.self, forKey: .initialShares) ?? 0
        totalFees = try c.decodeIfPresent(Double.self, forKey: .totalFees) ?? 0
        realizedPnL = try c.decodeIfPresent(Double.self, forKey: .realizedPnL) ?? 0
        buys = try c.decodeIfPresent(Int.self, forKey: .buys) ?? 0
        sells = try c.decodeIfPresent(Int.self, forKey: .sells) ?? 0
        wins = try c.decodeIfPresent(Int.self, forKey: .wins) ?? 0
        scoredSells = try c.decodeIfPresent(Int.self, forKey: .scoredSells) ?? 0
        lower = try c.decodeIfPresent(Double.self, forKey: .lower) ?? 0
        upper = try c.decodeIfPresent(Double.self, forKey: .upper) ?? 0
        anchor = try c.decodeIfPresent(Double.self, forKey: .anchor) ?? 0
        step = try c.decodeIfPresent(Double.self, forKey: .step) ?? 0
        quantity = try c.decodeIfPresent(Double.self, forKey: .quantity) ?? 0
        eligible = try c.decodeIfPresent(Double.self, forKey: .eligible) ?? decodedShares
        t0 = try c.decodeIfPresent(Bool.self, forKey: .t0) ?? false
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        lastTimestamp = try c.decodeIfPresent(String.self, forKey: .lastTimestamp) ?? ""
        fills = try c.decodeIfPresent([LegacyShadowFill].self, forKey: .fills) ?? []
        days = try c.decodeIfPresent([LegacyShadowDay].self, forKey: .days) ?? []
    }

    private var markPrice: Double { lastPrice > 0 ? lastPrice : anchor }
    var lastEquityChange: Double { cash + shares * markPrice - capital }
    var holdOnlyChange: Double { initialShares * (markPrice - initialPrice) }
}

struct LegacyDCAEventArchive: Codable, Identifiable {
    var id: String
    var planID: String
    var code: String
    var name: String
    var dueDate: String
    var amount: Double
    var status: String
    var rawJSON: String
}

struct LegacySettingsArchive: Codable, Identifiable {
    var id: String
    var title: String
    var rawJSON: String
}

struct GridReplayResult: Identifiable {
    var id: UUID = UUID()
    var code: String
    var day: String
    var fills: Int
    var buyCount: Int
    var sellCount: Int
    var startCapital: Double
    var endingValue: Double
    var fees: Double
    var coverage: Double
    var profit: Double { endingValue - startCapital }
}

struct GridRecommendation {
    var anchor: Double
    var stepPercent: Double
    var levels: Int
    var score: Int
    var daysUsed: Int
    var medianDailyRangePercent: Double
    var summary: String
}

struct AIAnalysisConfig: Codable {
    var endpoint = "https://api.deepseek.com"
    var model = "deepseek-flash"
    var systemPrompt = "你是一个谨慎的投资研究助手。依据给定数据总结趋势、风险与待核对信息，不预测确定收益，不替用户下单。明确区分事实和推断。"

    private enum CodingKeys: String, CodingKey { case endpoint, model, systemPrompt }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? "https://api.deepseek.com"
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-flash"
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? "你是一个谨慎的投资研究助手。依据给定数据总结趋势、风险与待核对信息，不预测确定收益，不替用户下单。明确区分事实和推断。"
    }
}

struct LedgerEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = .now
    var code: String
    var name: String
    var side: Side
    var quantity: Double
    var price: Double
    var fee: Double
    var realizedPnL: Double
    var linkedCash: Bool
    // Optional so backups created before asset-kind tagging remain readable.
    var kind: Holding.Kind? = nil

    enum Side: String, Codable { case buy, sell }
    var gross: Double { quantity * price }
}

struct PortfolioData: Codable {
    var quotes: [Quote] = []
    var quoteAlerts: [QuoteAlert] = []
    var holdings: [Holding] = []
    var allocationTargets: [AllocationTarget] = []
    var snapshots: [PortfolioSnapshot] = []
    var cashFlows: [CashFlow] = []
    var fundNAVHistory: [FundNAVPoint] = []
    var fundTransactions: [FundTransaction] = []
    var fundFeePolicies: [FundFeePolicy] = []
    var fundDCAPlans: [FundDCAPlan] = []
    var dayGridPlans: [DayGridPlan] = []
    var legacyGridArchives: [LegacyGridArchive] = []
    var legacyShadowArchives: [LegacyShadowArchive] = []
    var legacyDCAEvents: [LegacyDCAEventArchive] = []
    var legacySettingsArchives: [LegacySettingsArchive] = []
    var aiAnalysisConfig = AIAnalysisConfig()
    var ledger: [LedgerEntry] = []
    var cash: Double = 0
    var cashLinkedByDefault = false
    var appearance: AppAppearance = .system
    var quoteRefreshSeconds = 60
    var investmentProfile = InvestmentProfile()
    var tradePlans: [TradePlan] = []

    private enum CodingKeys: String, CodingKey {
        case quotes, quoteAlerts, holdings, allocationTargets, snapshots, cashFlows, fundNAVHistory, fundTransactions, fundFeePolicies, fundDCAPlans, dayGridPlans, legacyGridArchives, legacyShadowArchives, legacyDCAEvents, legacySettingsArchives, aiAnalysisConfig, ledger, cash, cashLinkedByDefault, appearance, quoteRefreshSeconds, investmentProfile, tradePlans
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quotes = try c.decodeIfPresent([Quote].self, forKey: .quotes) ?? []
        quoteAlerts = try c.decodeIfPresent([QuoteAlert].self, forKey: .quoteAlerts) ?? []
        holdings = try c.decodeIfPresent([Holding].self, forKey: .holdings) ?? []
        allocationTargets = try c.decodeIfPresent([AllocationTarget].self, forKey: .allocationTargets) ?? []
        snapshots = try c.decodeIfPresent([PortfolioSnapshot].self, forKey: .snapshots) ?? []
        cashFlows = try c.decodeIfPresent([CashFlow].self, forKey: .cashFlows) ?? []
        fundNAVHistory = try c.decodeIfPresent([FundNAVPoint].self, forKey: .fundNAVHistory) ?? []
        fundTransactions = try c.decodeIfPresent([FundTransaction].self, forKey: .fundTransactions) ?? []
        fundFeePolicies = try c.decodeIfPresent([FundFeePolicy].self, forKey: .fundFeePolicies) ?? []
        fundDCAPlans = try c.decodeIfPresent([FundDCAPlan].self, forKey: .fundDCAPlans) ?? []
        dayGridPlans = try c.decodeIfPresent([DayGridPlan].self, forKey: .dayGridPlans) ?? []
        legacyGridArchives = try c.decodeIfPresent([LegacyGridArchive].self, forKey: .legacyGridArchives) ?? []
        legacyShadowArchives = try c.decodeIfPresent([LegacyShadowArchive].self, forKey: .legacyShadowArchives) ?? []
        legacyDCAEvents = try c.decodeIfPresent([LegacyDCAEventArchive].self, forKey: .legacyDCAEvents) ?? []
        legacySettingsArchives = try c.decodeIfPresent([LegacySettingsArchive].self, forKey: .legacySettingsArchives) ?? []
        aiAnalysisConfig = try c.decodeIfPresent(AIAnalysisConfig.self, forKey: .aiAnalysisConfig) ?? AIAnalysisConfig()
        ledger = try c.decodeIfPresent([LedgerEntry].self, forKey: .ledger) ?? []
        cash = try c.decodeIfPresent(Double.self, forKey: .cash) ?? 0
        cashLinkedByDefault = try c.decodeIfPresent(Bool.self, forKey: .cashLinkedByDefault) ?? false
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        quoteRefreshSeconds = min(600, max(0, try c.decodeIfPresent(Int.self, forKey: .quoteRefreshSeconds) ?? 60))
        investmentProfile = try c.decodeIfPresent(InvestmentProfile.self, forKey: .investmentProfile) ?? InvestmentProfile()
        tradePlans = try c.decodeIfPresent([TradePlan].self, forKey: .tradePlans) ?? []
    }
}
