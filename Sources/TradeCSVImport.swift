import Foundation

struct TradeImportDraft: Identifiable {
    var id = UUID()
    var rowNumber: Int
    var code: String
    var name: String
    var date: Date?
    var side: LedgerEntry.Side?
    var quantity: Double
    var price: Double
    var fee: Double
    var error: String?
    var selected = true

    var isValid: Bool { error == nil && date != nil && side != nil && !code.isEmpty && quantity > 0 && price > 0 }
}

enum TradeCSVParser {
    private static let aliases: [String: [String]] = [
        "date": ["日期", "成交日期", "委托日期", "发生日期", "交易日期", "成交时间", "时间", "date", "time"],
        "code": ["代码", "证券代码", "股票代码", "基金代码", "标的代码", "code", "symbol"],
        "name": ["名称", "证券名称", "股票名称", "基金名称", "标的", "简称", "name"],
        "side": ["方向", "买卖", "买卖方向", "操作", "交易类型", "业务类型", "委托类型", "类型", "side", "type", "action"],
        "price": ["价格", "成交价", "成交价格", "委托价", "均价", "成交均价", "price", "avg"],
        "quantity": ["数量", "成交数量", "份额", "委托数量", "股数", "份数", "qty", "quantity", "shares"],
        "fee": ["手续费", "费用", "佣金", "总费用", "结算费", "fee", "commission"],
        "amount": ["成交金额", "成交额", "合计金额", "结算金额", "金额", "total", "cash"]
    ]

    static func parse(_ text: String) -> [TradeImportDraft] {
        let lines = text.components(separatedBy: .newlines).enumerated().filter { !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = lines.first else { return [] }
        let header = split(first.element).map(normalize)
        var columns: [String: Int] = [:]
        for (key, words) in aliases {
            if let index = header.firstIndex(where: { cell in words.contains(where: { let alias = normalize($0); return alias == cell || cell.contains(alias) }) }) { columns[key] = index }
        }
        let hasHeader = ["date", "code", "side", "price", "quantity"].filter { columns[$0] != nil }.count >= 3
        let body = hasHeader ? Array(lines.dropFirst()) : lines
        return body.map { row in
            let fields = split(row.element)
            func cell(_ key: String) -> String {
                guard let i = columns[key], fields.indices.contains(i) else { return "" }
                return fields[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let codeSource = hasHeader ? cell("code") : fields.first(where: { $0.range(of: #"\d{6}"#, options: .regularExpression) != nil }) ?? ""
            let code = codeSource.range(of: #"\d{6}"#, options: .regularExpression).map { String(codeSource[$0]) } ?? ""
            let name = hasHeader ? cell("name") : ""
            let dateSource = hasHeader ? cell("date") : fields.first(where: { parseDate($0) != nil }) ?? ""
            let date = parseDate(dateSource)
            let sideSource = hasHeader ? cell("side") : fields.first(where: { side($0) != nil }) ?? ""
            let parsedSide = side(sideSource)
            var price = number(hasHeader ? cell("price") : "")
            var quantity = number(hasHeader ? cell("quantity") : "")
            if hasHeader, quantity <= 0, columns["amount"] != nil, price > 0 {
                quantity = (abs(number(cell("amount"))) / price).rounded()
            }
            if !hasHeader {
                let numerics = fields.map(number).filter { $0 > 0 }
                price = numerics.first(where: { $0 < 100_000 && $0.rounded() != $0 }) ?? numerics.first ?? 0
                quantity = numerics.first(where: { $0 >= 1 && $0.rounded() == $0 }) ?? 0
            }
            let fee = abs(number(hasHeader ? cell("fee") : ""))
            var problems: [String] = []
            if code.isEmpty { problems.append("代码未识别") }
            if date == nil { problems.append("日期未识别") }
            if parsedSide == nil { problems.append("方向未识别") }
            if price <= 0 { problems.append("价格无效") }
            if quantity <= 0 { problems.append("数量无效") }
            return TradeImportDraft(rowNumber: row.offset + 1, code: code, name: name.isEmpty ? code : name,
                date: date, side: parsedSide, quantity: quantity, price: price, fee: fee,
                error: problems.isEmpty ? nil : problems.joined(separator: "、"), selected: problems.isEmpty)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "*" && $0 != ":" && $0 != "：" }
    }
    private static func split(_ line: String) -> [String] {
        let delimiter: Character = line.contains("\t") ? "\t" : ","
        var fields: [String] = [], current = "", quoted = false
        var chars = Array(line); var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\"" {
                if quoted && index + 1 < chars.count && chars[index + 1] == "\"" { current.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if c == delimiter && !quoted { fields.append(current); current = "" }
            else { current.append(c) }
            index += 1
        }
        fields.append(current)
        return fields
    }
    private static func number(_ raw: String) -> Double {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = value.hasPrefix("(") || value.hasPrefix("（") || value.hasSuffix("-")
        value = value.replacingOccurrences(of: #"[,，\s¥￥$%()]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "（", with: "").replacingOccurrences(of: "）", with: "")
        guard let parsed = Double(value), parsed.isFinite else { return 0 }
        return negative ? -abs(parsed) : parsed
    }
    private static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd", "yyyyMMdd", "yyyy.MM.dd"]
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for pattern in patterns { formatter.dateFormat = pattern; if let date = formatter.date(from: value) { return date } }
        return nil
    }
    private static func side(_ raw: String) -> LedgerEntry.Side? {
        let value = raw.lowercased()
        if ["卖出", "卖", "赎回", "sell", "out", "清仓"].contains(where: { value.contains($0) }) { return .sell }
        if ["买入", "买", "申购", "认购", "buy", "in", "建仓"].contains(where: { value.contains($0) }) { return .buy }
        return nil
    }
}

@MainActor
extension PortfolioStore {
    /// Imports historical ETF/stock transactions into the ledger only. Current
    /// positions and cash are deliberately left untouched to avoid replaying
    /// historical fills on top of today's broker balances.
    @discardableResult
    func importTradeLedger(_ drafts: [TradeImportDraft]) throws -> Int {
        let chosen = drafts.filter { $0.selected && $0.isValid }
        guard !chosen.isEmpty else { throw StoreError.invalidTrade }
        let dayFormatter = DateFormatter(); dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); dayFormatter.dateFormat = "yyyy-MM-dd"
        func sameTrade(_ lhs: LedgerEntry, code: String, side: LedgerEntry.Side, quantity: Double, price: Double, date: Date) -> Bool {
            lhs.code == code && (lhs.kind ?? .etf) == .etf && lhs.side == side
                && dayFormatter.string(from: lhs.date) == dayFormatter.string(from: date)
                && abs(lhs.quantity - quantity) < 1e-8 && abs(lhs.price - price) < 1e-8
        }
        func key(code: String, side: LedgerEntry.Side, quantity: Double, price: Double, date: Date) -> String {
            "\(code)|\(dayFormatter.string(from: date))|\(side.rawValue)|\(String(format: "%.8f", quantity))|\(String(format: "%.8f", price))"
        }
        var seen = Set(data.ledger.filter { ($0.kind ?? .etf) == .etf }.map {
            key(code: $0.code, side: $0.side, quantity: $0.quantity, price: $0.price, date: $0.date)
        })
        let newRows = chosen.filter { draft in
            let duplicate = data.ledger.contains { sameTrade($0, code: draft.code, side: draft.side!, quantity: draft.quantity, price: draft.price, date: draft.date!) }
            return !duplicate && seen.insert(key(code: draft.code, side: draft.side!, quantity: draft.quantity, price: draft.price, date: draft.date!)).inserted
        }
        guard !newRows.isEmpty else { return 0 }
        struct Event { var date: Date; var code: String; var side: LedgerEntry.Side; var quantity: Double; var price: Double; var fee: Double; var rowNumber: Int }
        // Replay the selected file as a closed history so the current broker
        // balance is never used as a fictitious starting position.
        let events = chosen.map {
            Event(date: $0.date!, code: $0.code, side: $0.side!, quantity: $0.quantity,
                  price: $0.price, fee: $0.fee, rowNumber: $0.rowNumber)
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.rowNumber < $1.rowNumber
        }
        var quantityByCode: [String: Double] = [:]
        var costByCode: [String: Double] = [:]
        var realizedByRow: [Int: Double] = [:]
        for event in events {
            guard event.quantity.isFinite, event.quantity > 0, event.price.isFinite, event.price > 0,
                  event.fee.isFinite, event.fee >= 0 else { throw StoreError.invalidImportedLedger }
            let quantity = quantityByCode[event.code, default: 0]
            let cost = costByCode[event.code, default: 0]
            switch event.side {
            case .buy:
                quantityByCode[event.code] = quantity + event.quantity
                costByCode[event.code] = cost + event.quantity * event.price + event.fee
            case .sell:
                guard quantity + 1e-8 >= event.quantity, quantity > 0 else { throw StoreError.invalidImportedLedger }
                let averageCost = cost / quantity
                realizedByRow[event.rowNumber] = (event.price - averageCost) * event.quantity - event.fee
                quantityByCode[event.code] = max(0, quantity - event.quantity)
                costByCode[event.code] = max(0, cost - averageCost * event.quantity)
            }
        }
        var entries: [LedgerEntry] = []
        for draft in newRows {
            guard let date = draft.date, let side = draft.side else { continue }
            entries.append(LedgerEntry(date: date, code: draft.code, name: draft.name,
                side: side, quantity: draft.quantity, price: draft.price, fee: draft.fee,
                realizedPnL: realizedByRow[draft.rowNumber] ?? 0, linkedCash: false, kind: .etf))
        }
        data.ledger.append(contentsOf: entries)
        data.ledger.sort { $0.date < $1.date }
        save()
        return entries.count
    }
}
