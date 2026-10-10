import Foundation
import CoreFoundation
import SwiftUI

@MainActor
final class PortfolioStore: ObservableObject {
    @Published var data = PortfolioData()
    @Published var intradayBars: [IntradayBar] = []
    @Published var dailyBars: [String: [DailyBar]] = [:]
    @Published var sourceStatus = "等待刷新"
    @Published var fundNAVStatus = "尚未更新基金净值"
    @Published var fundDCAStatus = "暂无定投补记"
    @Published var isRefreshingFunds = false
    @Published var isRefreshingQuotes = false
    @Published var nasSyncStatus = "未配置 NAS 同步"
    private let key = "guanpan.pro.native.portfolio.v1"
    private let gridBarsFilename = "guanpan-intraday-bars.json"
    private let dailyBarsFilename = "guanpan-daily-bars.json"
    private var nasSyncTask: Task<Void, Never>?
    private var applyingNASData = false

    init() {
        load()
        loadIntradayBars()
        loadDailyBars()
        processAutomaticDCA()
    }
    var appearance: AppAppearance { get { data.appearance } set { data.appearance = newValue; save() } }
    var totalMarketValue: Double { data.holdings.reduce(0) { $0 + $1.marketValue } }
    var totalAsset: Double { totalMarketValue + data.cash }
    var totalPnL: Double { data.holdings.reduce(0) { $0 + $1.pnl } }
    var realizedPnL: Double {
        data.ledger.reduce(0) { $0 + $1.realizedPnL }
            + data.fundTransactions.filter { $0.side == .dividend && $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
    }

    func load() {
        guard let raw = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(PortfolioData.self, from: raw) else { return }
        data = value
    }
    private func gridBarsURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(gridBarsFilename)
    }
    private func loadIntradayBars() {
        guard let url = gridBarsURL(), let raw = try? Data(contentsOf: url) else { return }
        if let rows = try? JSONDecoder().decode([IntradayBar].self, from: raw) {
            intradayBars = rows
        } else if let text = String(data: raw, encoding: .utf8) {
            var rows: [IntradayBar] = []
            for line in text.split(whereSeparator: \.isNewline) {
                let bytes = Data(line.utf8)
                if let bar = try? JSONDecoder().decode(IntradayBar.self, from: bytes) { rows.append(bar) }
                else if let bars = try? JSONDecoder().decode([IntradayBar].self, from: bytes) { rows.append(contentsOf: bars) }
            }
            intradayBars = rows
        }
    }
    private func dailyBarsURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(dailyBarsFilename)
    }
    private func loadDailyBars() {
        guard let url = dailyBarsURL(), let raw = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([DailyBar].self, from: raw) else { return }
        dailyBars = Dictionary(grouping: rows, by: \.code).mapValues { $0.sorted { $0.date < $1.date } }
    }
    func saveDailyBars() {
        guard let url = dailyBarsURL() else { return }
        let rows = dailyBars.values.flatMap { $0 }.sorted { $0.code == $1.code ? $0.date < $1.date : $0.code < $1.code }
        if let raw = try? JSONEncoder().encode(rows) { try? raw.write(to: url, options: .atomic) }
    }
    func fetchDailyBars(code rawCode: String, count: Int = 640, force: Bool = false) async throws -> [DailyBar] {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw URLError(.badURL) }
        if !force, let cached = dailyBars[code], !cached.isEmpty { return cached }
        let symbol = tencentSymbol(code)
        let endpoints = [
            "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get",
            "https://ifzq.gtimg.cn/appstock/app/newfqkline/get",
            "https://web.ifzq.gtimg.cn/appstock/app/newfqkline/get"
        ]
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for endpoint in endpoints {
            var components = URLComponents(string: endpoint)!
            components.queryItems = [URLQueryItem(name: "param", value: "\(symbol),day,,,\(min(max(count, 30), 640)),qfq")]
            guard let url = components.url else { continue }
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 10
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: bytes, encoding: .utf8),
                      let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { throw URLError(.badServerResponse) }
                let payload = Data(text[start...end].utf8)
                guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      let data = root["data"] as? [String: Any],
                      let node = data[symbol] as? [String: Any],
                      let bars = (node["qfqday"] as? [[Any]]) ?? (node["day"] as? [[Any]]) else { throw URLError(.cannotParseResponse) }
                let result = bars.compactMap { row -> DailyBar? in
                    guard row.count >= 6, let date = row[0] as? String else { return nil }
                    let values = row[1...5].compactMap { item -> Double? in
                        if let n = item as? NSNumber { return n.doubleValue }
                        if let s = item as? String { return Double(s) }
                        return nil
                    }
                    guard values.count == 5, values[1] > 0 else { return nil }
                    return DailyBar(code: code, date: date, open: values[0], close: values[1], high: values[2], low: values[3], volume: values[4])
                }.sorted { $0.date < $1.date }
                guard !result.isEmpty else { throw URLError(.cannotParseResponse) }
                dailyBars[code] = result; saveDailyBars(); return result
            } catch { lastError = error }
        }
        if let cached = dailyBars[code], !cached.isEmpty { return cached }
        throw lastError
    }
    func saveIntradayBars() {
        guard let url = gridBarsURL() else { return }
        let encoder = JSONEncoder()
        let lines = intradayBars.compactMap { try? encoder.encode($0) }
        let raw = lines.reduce(into: Data()) { result, line in result.append(line); result.append(0x0A) }
        try? raw.write(to: url, options: .atomic)
    }
    func appendIntradayBars(_ bars: [IntradayBar]) {
        guard !bars.isEmpty, let url = gridBarsURL() else { return }
        let encoder = JSONEncoder()
        var raw = Data()
        for bar in bars {
            guard let line = try? encoder.encode(bar) else { continue }
            raw.append(line); raw.append(0x0A)
        }
        guard !raw.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: raw)
        } catch { saveIntradayBars() }
    }
    func save() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(raw, forKey: key)
        if !applyingNASData { scheduleNASSync() }
    }

    func configureNASSync() {
        nasSyncTask?.cancel()
        guard UserDefaults.standard.bool(forKey: NASSyncService.automaticKey) else {
            nasSyncStatus = "自动同步已关闭"
            return
        }
        scheduleNASSync(delay: 1)
    }

    private func makeNASDocument() -> NativeSyncDocument {
        NativeSyncDocument(data: data, intradayBars: intradayBars,
                           dailyBars: dailyBars.values.flatMap { $0 }.sorted {
                               $0.code == $1.code ? $0.date < $1.date : $0.code < $1.code
                           })
    }

    private func hasNASUserData(_ document: NativeSyncDocument) -> Bool {
        let d = document.data
        return !d.holdings.isEmpty || !d.ledger.isEmpty || !d.fundTransactions.isEmpty ||
            !d.fundNAVHistory.isEmpty || !d.fundFeePolicies.isEmpty || !d.fundDCAPlans.isEmpty ||
            !d.cashFlows.isEmpty || !d.snapshots.isEmpty || !d.quotes.isEmpty || !d.quoteAlerts.isEmpty ||
            !d.allocationTargets.isEmpty || !d.tradePlans.isEmpty || !d.dayGridPlans.isEmpty ||
            !d.legacyGridArchives.isEmpty || !d.legacyShadowArchives.isEmpty || !d.legacyDCAEvents.isEmpty ||
            !d.legacySettingsArchives.isEmpty || d.cash != 0 || d.cashLinkedByDefault || d.appearance != .system ||
            d.quoteRefreshSeconds != 60 || d.investmentProfile.style != "swing" || d.investmentProfile.risk != "bal" ||
            d.investmentProfile.maxPositionPercent != 35 || d.investmentProfile.horizon != "1-3个月" ||
            !d.investmentProfile.preference.isEmpty || !d.investmentProfile.avoid.isEmpty ||
            !d.investmentProfile.method.isEmpty || !d.investmentProfile.goal.isEmpty ||
            !document.intradayBars.isEmpty || !document.dailyBars.isEmpty
    }

    private func scheduleNASSync(delay: UInt64 = 4) {
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: NASSyncService.urlKey) ?? ""
        let token = NASCredentialStore.load() ?? ""
        guard defaults.bool(forKey: NASSyncService.automaticKey), !url.isEmpty, !token.isEmpty else { return }
        nasSyncTask?.cancel()
        nasSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await synchronizeNASSafely()
        }
    }

    func synchronizeNASSafely() async {
        guard !applyingNASData else { return }
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: NASSyncService.urlKey) ?? ""
        let token = NASCredentialStore.load() ?? ""
        guard !url.isEmpty, !token.isEmpty else { nasSyncStatus = "请填写 NAS 地址和同步口令"; return }
        do {
            nasSyncStatus = "正在检查 NAS…"
            let remote = try await NASSyncService.get(base: url, token: token)
            let local = makeNASDocument()
            let localFingerprint = try NASSyncService.fingerprint(local)
            let baseline = defaults.string(forKey: NASSyncService.fingerprintKey)
            let knownRevision = defaults.integer(forKey: NASSyncService.revisionKey)
            guard let remoteDocument = remote.data else {
                let legacy = try await NASSyncService.legacyBackup(base: url, token: token)
                if let legacyBytes = legacy.data,
                   let migrated = try? LegacyMigration.decodePackage(legacyBytes) {
                    let migratedDocument = NativeSyncDocument(data: migrated.data,
                        intradayBars: migrated.intradayBars, dailyBars: [])
                    if hasNASUserData(migratedDocument) {
                        if !hasNASUserData(local) {
                            applyNASDocument(migratedDocument)
                            let imported = makeNASDocument()
                            let result = try await NASSyncService.put(base: url, token: token,
                                document: imported, expectedRevision: remote.revision)
                            recordNASSync(revision: result.revision, document: imported)
                            nasSyncStatus = "已将 NAS 网页账本迁入原生空间并同步（版本 \(result.revision)）"
                        } else if try NASSyncService.fingerprint(migratedDocument) == localFingerprint {
                            let result = try await NASSyncService.put(base: url, token: token,
                                document: local, expectedRevision: remote.revision)
                            recordNASSync(revision: result.revision, document: local)
                            nasSyncStatus = "本机与 NAS 网页账本一致，已建立原生同步（版本 \(result.revision)）"
                        } else {
                            nasSyncStatus = "NAS 有网页账本，本机也有不同数据；为避免覆盖，请先导出本机备份并选择同步方向"
                        }
                        return
                    }
                }
                if hasNASUserData(local) {
                    let result = try await NASSyncService.put(base: url, token: token, document: local,
                                                              expectedRevision: remote.revision)
                    recordNASSync(revision: result.revision, document: local)
                    nasSyncStatus = "已上传到 NAS（版本 \(result.revision)）"
                } else {
                    recordNASSync(revision: remote.revision, document: local)
                    nasSyncStatus = "NAS 暂无数据"
                }
                return
            }
            let remoteFingerprint = try NASSyncService.fingerprint(remoteDocument)
            if baseline == nil {
                if !hasNASUserData(local) {
                    applyNASDocument(remoteDocument)
                    recordNASSync(revision: remote.revision, document: remoteDocument)
                    nasSyncStatus = "已从 NAS 恢复（版本 \(remote.revision)）"
                } else if localFingerprint == remoteFingerprint {
                    recordNASSync(revision: remote.revision, document: local)
                    nasSyncStatus = "本机与 NAS 数据一致"
                } else {
                    nasSyncStatus = "本机和 NAS 都有数据，请选择下载或上传，自动同步已暂停"
                }
                return
            }
            if remote.revision == knownRevision {
                if localFingerprint != baseline {
                    let result = try await NASSyncService.put(base: url, token: token, document: local,
                                                              expectedRevision: remote.revision)
                    recordNASSync(revision: result.revision, document: local)
                    nasSyncStatus = "已同步到 NAS（版本 \(result.revision)）"
                } else {
                    nasSyncStatus = "已同步（版本 \(remote.revision)）"
                }
            } else if localFingerprint == baseline {
                applyNASDocument(remoteDocument)
                recordNASSync(revision: remote.revision, document: remoteDocument)
                nasSyncStatus = "已接收另一台设备的数据（版本 \(remote.revision)）"
            } else if remoteFingerprint == baseline {
                let result = try await NASSyncService.put(base: url, token: token, document: local,
                                                          expectedRevision: remote.revision)
                recordNASSync(revision: result.revision, document: local)
                nasSyncStatus = "已上传本机更改（版本 \(result.revision)）"
            } else {
                nasSyncStatus = "本机和 NAS 都有新更改，已暂停自动覆盖；请先下载备份再选择同步方向"
            }
        } catch {
            nasSyncStatus = "NAS 同步失败：\(error.localizedDescription)"
        }
    }

    func downloadFromNAS() async {
        let defaults = UserDefaults.standard
        do {
            let response = try await NASSyncService.get(
                base: defaults.string(forKey: NASSyncService.urlKey) ?? "",
                token: NASCredentialStore.load() ?? "")
            if let document = response.data {
                applyNASDocument(document)
                recordNASSync(revision: response.revision, document: document)
                nasSyncStatus = "已从 NAS 下载（版本 \(response.revision)）"
                return
            }
            let legacy = try await NASSyncService.legacyBackup(
                base: defaults.string(forKey: NASSyncService.urlKey) ?? "",
                token: NASCredentialStore.load() ?? "")
            guard let bytes = legacy.data, let migrated = try? LegacyMigration.decodePackage(bytes) else {
                nasSyncStatus = "NAS 当前没有可识别的原生或网页账本数据"
                return
            }
            let imported = NativeSyncDocument(data: migrated.data, intradayBars: migrated.intradayBars, dailyBars: [])
            applyNASDocument(imported)
            let saved = makeNASDocument()
            let result = try await NASSyncService.put(base: defaults.string(forKey: NASSyncService.urlKey) ?? "",
                token: NASCredentialStore.load() ?? "", document: saved, expectedRevision: response.revision)
            recordNASSync(revision: result.revision, document: saved)
            nasSyncStatus = "网页账本已迁入原生空间（版本 \(result.revision)）"
        } catch { nasSyncStatus = "下载失败：\(error.localizedDescription)" }
    }

    func uploadToNAS(allowEmptyOverwrite: Bool = false) async {
        let defaults = UserDefaults.standard
        do {
            let url = defaults.string(forKey: NASSyncService.urlKey) ?? ""
            let token = NASCredentialStore.load() ?? ""
            let remote = try await NASSyncService.get(base: url, token: token)
            let document = makeNASDocument()
            let result = try await NASSyncService.put(base: url, token: token, document: document,
                expectedRevision: remote.revision, allowEmptyOverwrite: allowEmptyOverwrite)
            recordNASSync(revision: result.revision, document: document)
            nasSyncStatus = "已上传到 NAS（版本 \(result.revision)）"
        } catch { nasSyncStatus = "上传失败：\(error.localizedDescription)" }
    }

    private func applyNASDocument(_ document: NativeSyncDocument) {
        applyingNASData = true
        replaceData(document.data, intradayBars: document.intradayBars, dailyBars: document.dailyBars)
        applyingNASData = false
    }

    private func recordNASSync(revision: Int, document: NativeSyncDocument) {
        let defaults = UserDefaults.standard
        defaults.set(revision, forKey: NASSyncService.revisionKey)
        if let fingerprint = try? NASSyncService.fingerprint(document) {
            defaults.set(fingerprint, forKey: NASSyncService.fingerprintKey)
        }
    }
    func lookupETFQuote(code rawCode: String) async throws -> Quote? {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
        let symbol = tencentSymbol(code)
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(symbol)&_t=\(Int(Date().timeIntervalSince1970))") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let text = decodeTencent(bytes)
        guard let quote = parseTencent(text)[symbol], !quote.name.isEmpty else { return nil }
        return Quote(code: code, name: quote.name, price: quote.price,
                     changePct: quote.changePct, updatedAt: quote.timestamp)
    }

    func refreshQuotes() {
        guard !isRefreshingQuotes else { return }
        Task { _ = await performQuoteRefresh(captureIntraday: true) }
    }

    func refreshQuotesForBackground() async -> Bool {
        guard data.quoteRefreshSeconds > 0, !isRefreshingQuotes else { return false }
        return await performQuoteRefresh(captureIntraday: false)
    }

    private func performQuoteRefresh(captureIntraday: Bool) async -> Bool {
        // Tencent's stock quote endpoint does not return OTC fund NAVs. Never send
        // fund codes there or present a stock quote as a fund valuation.
        let shadowCodes = data.legacyShadowArchives.filter { !$0.closed }.map(\.code)
        let symbols = Set(data.quotes.map(\.code) + data.holdings.filter { $0.kind == .etf }.map(\.code) + shadowCodes)
        guard !symbols.isEmpty else { sourceStatus = "还没有标的"; return false }
        let requestCodes = symbols.map(tencentSymbol).sorted()
        guard let url = URL(string: "https://qt.gtimg.cn/q=" + requestCodes.joined(separator: ",") + "&_t=" + String(Int(Date().timeIntervalSince1970))) else {
            sourceStatus = "行情请求地址无效"; return false
        }
        sourceStatus = "正在刷新行情…"
        isRefreshingQuotes = true
        defer { isRefreshingQuotes = false }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 12
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let text = decodeTencent(bytes)
            let values = parseTencent(text)
            guard !values.isEmpty else { sourceStatus = "接口未返回可识别报价"; return false }
            for i in data.quotes.indices {
                if let q = values[tencentSymbol(data.quotes[i].code)] {
                    data.quotes[i].price = q.price
                    data.quotes[i].changePct = q.changePct
                    data.quotes[i].updatedAt = q.timestamp
                }
            }
            for i in data.holdings.indices where data.holdings[i].kind == .etf {
                if let q = values[tencentSymbol(data.holdings[i].code)] { data.holdings[i].current = q.price }
            }
            if Self.isRegularTradingSession(Date()) {
                checkQuoteAlerts(using: values)
                if captureIntraday {
                    let liveCodes = Set(data.quotes.map(\.code) + data.holdings.filter { $0.kind == .etf }.map(\.code) + shadowCodes)
                    let live = liveCodes.compactMap { code -> (String, Double)? in
                        guard let quote = values[tencentSymbol(code)], Self.isFreshQuote(quote.timestamp, now: .now) else { return nil }
                        return (code, quote.price)
                    }
                    captureMinuteQuotes(live)
                    let shadowQuotes = live.compactMap { item -> (String, Double, Date)? in
                        let code = item.0
                        guard let quote = values[tencentSymbol(code)], let timestamp = quote.timestamp else { return nil }
                        return (code, quote.price, timestamp)
                    }
                    advanceLegacyShadowSimulations(shadowQuotes)
                }
            }
            save(); sourceStatus = "行情已更新 · \(Date.now.formatted(date: .omitted, time: .shortened))"
            return true
        } catch {
            sourceStatus = "行情刷新失败：\(error.localizedDescription)"
            return false
        }
    }

    func addQuoteAlert(code: String, name: String, target: Double, direction: QuoteAlert.Direction) throws {
        guard !code.isEmpty, target.isFinite, target > 0 else { throw StoreError.invalidAlert }
        data.quoteAlerts.append(QuoteAlert(code: code, name: name.isEmpty ? code : name,
            target: target, direction: direction, enabled: true, lastTriggeredAt: nil))
        save()
    }

    func removeQuoteAlert(_ alert: QuoteAlert) {
        data.quoteAlerts.removeAll { $0.id == alert.id }
        save()
    }

    func reenableQuoteAlert(_ alert: QuoteAlert) {
        guard let index = data.quoteAlerts.firstIndex(where: { $0.id == alert.id }) else { return }
        data.quoteAlerts[index].enabled = true
        data.quoteAlerts[index].lastTriggeredAt = nil
        save()
    }

    private func checkQuoteAlerts(using quotes: [String: (name: String, price: Double, changePct: Double, timestamp: Date?)]) {
        var changed = false
        for index in data.quoteAlerts.indices where data.quoteAlerts[index].enabled {
            let alert = data.quoteAlerts[index]
            guard let quote = quotes[tencentSymbol(alert.code)], quote.price.isFinite, quote.price > 0,
                  Self.isFreshQuote(quote.timestamp, now: .now) else { continue }
            let triggered = alert.direction == .above ? quote.price >= alert.target : quote.price <= alert.target
            guard triggered else { continue }
            data.quoteAlerts[index].enabled = false // one-shot; avoids repeated notifications on every refresh
            data.quoteAlerts[index].lastTriggeredAt = .now
            changed = true
            Task { try? await NativeNotifications.send(title: "觀盘 Pro · 价格提醒", body: "\(alert.name)（\(alert.code)）现价 \(quote.price)，已\(alert.direction == .above ? "达到上穿" : "达到下穿")目标 \(alert.target)。") }
        }
        if changed { save() }
    }

    private static func isRegularTradingSession(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return (570...690).contains(minute) || (780...900).contains(minute)
    }

    private static func isFreshQuote(_ timestamp: Date?, now: Date) -> Bool {
        guard let timestamp else { return false }
        let age = now.timeIntervalSince(timestamp)
        return age >= -90 && age <= 180
    }

    func refreshFundNAVs() {
        guard !isRefreshingFunds else { return }
        let codes = Array(Set(data.holdings.filter { $0.kind == .fund }.map(\.code)
            + data.fundTransactions.map(\.code))).sorted()
        guard !codes.isEmpty else { fundNAVStatus = "没有场外基金持仓或历史流水"; return }
        isRefreshingFunds = true
        fundNAVStatus = "正在逐只获取已公布净值…"
        Task {
            var updated = 0
            var failures: [String] = []
            for code in codes {
                do {
                    guard code.count == 6, code.allSatisfy(\.isNumber) else { failures.append(code); continue }
                    guard let url = URL(string: "https://fund.eastmoney.com/pingzhongdata/\(code).js") else { throw URLError(.badURL) }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 20
                    request.setValue("https://fund.eastmoney.com/", forHTTPHeaderField: "Referer")
                    let (bytes, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          let points = Self.parseFundNAVScript(bytes, code: code), !points.isEmpty else {
                        throw URLError(.cannotParseResponse)
                    }
                    let byDate = Dictionary(uniqueKeysWithValues: data.fundNAVHistory.filter { $0.code == code }.map { ($0.date, $0) })
                    var merged = byDate
                    for point in points { merged[point.date] = point }
                    data.fundNAVHistory.removeAll { $0.code == code }
                    data.fundNAVHistory.append(contentsOf: merged.values.sorted { $0.date < $1.date }.suffix(1800))
                    if let latest = points.last,
                       let index = data.holdings.firstIndex(where: { $0.kind == .fund && $0.code == code }) {
                        data.holdings[index].current = latest.nav
                    }
                    updated += 1
                } catch {
                    failures.append(code)
                }
            }
            let dcaBooked = processAutomaticDCA()
            let refreshedSnapshot = updated > 0 ? refreshTodaySnapshotIfPresent() : false
            save()
            isRefreshingFunds = false
            let snapshotNote = refreshedSnapshot ? "；今日已有快照已同步重算" : ""
            if dcaBooked > 0 { fundDCAStatus = "已按已公布净值补记定投 \(dcaBooked) 期；仅更新本机账本" }
            fundNAVStatus = failures.isEmpty
                ? "已更新 \(updated) 只基金的已公布净值（通常 T+1）\(snapshotNote)"
                : "更新 \(updated) 只，失败 \(failures.count) 只：\(failures.prefix(3).joined(separator: "、"))\(snapshotNote)"
        }
    }

    private func refreshTodaySnapshotIfPresent() -> Bool {
        let today = dayString(.now)
        guard let i = data.snapshots.firstIndex(where: { $0.date == today }) else { return false }
        data.snapshots[i].total = totalAsset
        data.snapshots[i].cash = data.cash
        data.snapshots[i].recordedAt = .now
        return true
    }

    private static func parseFundNAVScript(_ bytes: Data, code: String) -> [FundNAVPoint]? {
        guard let text = String(data: bytes, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"Data_netWorthTrend\s*=\s*(\[[\s\S]*?\])\s*;"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let json = String(text[range]).data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return nil }
        let points = rows.compactMap { row -> FundNAVPoint? in
            guard let rawTime = (row["x"] as? NSNumber)?.doubleValue,
                  let rawNAV = (row["y"] as? NSNumber)?.doubleValue,
                  rawNAV.isFinite, rawNAV > 0 else { return nil }
            let timestamp = rawTime > 100_000_000_000 ? rawTime / 1000 : rawTime
            let date = Date(timeIntervalSince1970: timestamp)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
            return FundNAVPoint(code: code, date: formatter.string(from: date), nav: rawNAV)
        }
        return points.sorted { $0.date < $1.date }
    }

    func addWatch(code: String, name: String) {
        guard !code.isEmpty, !data.quotes.contains(where: { $0.code == code }) else { return }
        data.quotes.append(Quote(code: code, name: name.isEmpty ? code : name, price: 0, changePct: 0, updatedAt: nil)); save()
    }

    private func tencentSymbol(_ raw: String) -> String {
        let c = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if c.hasPrefix("sh") || c.hasPrefix("sz") || c.hasPrefix("bj") || c.hasPrefix("hk") || c.hasPrefix("us") { return c }
        if c.count == 5, c.allSatisfy(\.isNumber) { return "hk" + c }
        if c.hasPrefix("6") || c.hasPrefix("9") || c.hasPrefix("5") || c.hasPrefix("11") || c.hasPrefix("50") || c.hasPrefix("51") || c.hasPrefix("56") || c.hasPrefix("58") { return "sh" + c }
        if c.hasPrefix("0") || c.hasPrefix("1") || c.hasPrefix("2") || c.hasPrefix("3") { return "sz" + c }
        if c.hasPrefix("4") || c.hasPrefix("8") { return "bj" + c }
        return "sh" + c
    }

    private func decodeTencent(_ bytes: Data) -> String {
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return String(data: bytes, encoding: .isoLatin1) ?? "" }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String(data: bytes, encoding: String.Encoding(rawValue: nsEncoding))
            ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    private func parseTencent(_ text: String) -> [String: (name: String, price: Double, changePct: Double, timestamp: Date?)] {
        var result: [String: (String, Double, Double, Date?)] = [:]
        let pattern = #"v_([a-zA-Z0-9]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges == 3 {
            let symbol = ns.substring(with: match.range(at: 1)).lowercased()
            let fields = ns.substring(with: match.range(at: 2)).split(separator: "~", omittingEmptySubsequences: false)
            guard fields.count > 32, let price = Double(fields[3]), price > 0 else { continue }
            let name = String(fields[1])
            let pct = Double(fields[32]) ?? 0
            let timestamp = fields.count > 30 ? parseTencentTimestamp(String(fields[30])) : nil
            result[symbol] = (name, price, pct / 100, timestamp)
        }
        return result
    }

    private func parseTencentTimestamp(_ raw: String) -> Date? {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 12 || digits.count == 14 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = digits.count == 14 ? "yyyyMMddHHmmss" : "yyyyMMddHHmm"
        return formatter.date(from: digits)
    }
    func addHolding(_ holding: Holding) { data.holdings.append(holding); save() }
    func allocationActualPercent(for holding: Holding) -> Double {
        guard totalAsset > 0, totalAsset.isFinite else { return 0 }
        return holding.marketValue / totalAsset * 100
    }
    func saveAllocationTarget(for holding: Holding, percent: Double) throws {
        guard percent.isFinite, (0...100).contains(percent) else { throw StoreError.invalidAllocationTarget }
        let target = AllocationTarget(code: holding.code, name: holding.name, kind: holding.kind, targetPercent: percent)
        if let i = data.allocationTargets.firstIndex(where: { $0.code == holding.code && $0.kind == holding.kind }) {
            data.allocationTargets[i] = target
        } else { data.allocationTargets.append(target) }
        save()
    }
    func removeAllocationTarget(for holding: Holding) {
        data.allocationTargets.removeAll { $0.code == holding.code && $0.kind == holding.kind }
        save()
    }
    func removeHolding(_ holding: Holding) {
        data.holdings.removeAll { $0.code == holding.code && $0.kind == holding.kind }
        if holding.kind == .fund { data.fundDCAPlans.removeAll { $0.code == holding.code } }
        save()
    }

    func upsertHolding(_ holding: Holding, oldCode: String? = nil) {
        if let oldCode, let i = data.holdings.firstIndex(where: { $0.code == oldCode && $0.kind == holding.kind }) {
            data.holdings[i] = holding
            if holding.kind == .fund, oldCode != holding.code {
                data.fundDCAPlans.removeAll { $0.code == oldCode }
            }
        } else if let i = data.holdings.firstIndex(where: { $0.code == holding.code && $0.kind == holding.kind }) {
            data.holdings[i] = holding
        } else { data.holdings.append(holding) }
        save()
    }

    func addDCAPlan(code: String, name: String, amount: Double, feeRatePercent: Double,
                    frequency: FundDCAPlan.Frequency, weekday: Int, monthDay: Int) throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), amount.isFinite, amount > 0,
              feeRatePercent.isFinite, (0...5).contains(feeRatePercent),
              (1...7).contains(weekday), (1...28).contains(monthDay),
              !data.fundDCAPlans.contains(where: { $0.code == code && $0.enabled }) else {
            throw StoreError.invalidTrade
        }
        data.fundDCAPlans.append(FundDCAPlan(code: code, name: name, amount: amount, feeRate: feeRatePercent / 100,
            frequency: frequency, weekday: weekday, monthDay: monthDay,
            startDate: dayString(.now), enabled: true, processedDates: []))
        save()
    }

    func removeDCAPlan(_ plan: FundDCAPlan) {
        data.fundDCAPlans.removeAll { $0.id == plan.id }
        save()
    }

    func setDCAPlan(_ plan: FundDCAPlan, enabled: Bool) {
        guard let index = data.fundDCAPlans.firstIndex(where: { $0.id == plan.id }) else { return }
        data.fundDCAPlans[index].enabled = enabled
        save()
    }

    /// Books a local DCA ledger entry only after the corresponding published
    /// NAV exists. It never touches reference cash and never places an order.
    @discardableResult
    func processAutomaticDCA() -> Int {
        var booked = 0
        for index in data.fundDCAPlans.indices where data.fundDCAPlans[index].enabled {
            let plan = data.fundDCAPlans[index]
            let groupedHistory = Dictionary(grouping: data.fundNAVHistory.filter {
                $0.code == plan.code && $0.date >= plan.startDate
            }, by: \.date)
            let history = groupedHistory.keys.sorted().compactMap { groupedHistory[$0]?.first }
            let navPoints = dcaExecutionPoints(history, plan: plan)
            for point in navPoints where !plan.processedDates.contains(point.date) {
                guard point.nav.isFinite, point.nav > 0 else { continue }
                let feeRate = plan.feeRate ?? 0.0015
                let fee = plan.amount * feeRate
                let netAmount = plan.amount - fee
                guard fee.isFinite, netAmount > 0 else { continue }
                let quantity = netAmount / point.nav
                guard quantity.isFinite, quantity > 0 else { continue }
                if let holdingIndex = data.holdings.firstIndex(where: { $0.code == plan.code && $0.kind == .fund }) {
                    var holding = data.holdings[holdingIndex]
                    let combinedQuantity = holding.quantity + quantity
                    let combinedCost = holding.quantity * holding.cost + plan.amount
                    guard combinedQuantity.isFinite, combinedCost.isFinite else { continue }
                    holding.quantity = combinedQuantity
                    holding.cost = combinedCost / combinedQuantity
                    if let latestNAV = data.fundNAVHistory.filter({ $0.code == plan.code }).max(by: { $0.date < $1.date }) {
                        holding.current = latestNAV.nav
                    }
                    data.holdings[holdingIndex] = holding
                } else {
                    let latest = data.fundNAVHistory.filter({ $0.code == plan.code }).max(by: { $0.date < $1.date })?.nav ?? point.nav
                    data.holdings.append(Holding(code: plan.code, name: plan.name, quantity: quantity,
                        cost: point.nav, current: latest, kind: .fund))
                }
                data.fundTransactions.append(FundTransaction(code: plan.code, name: plan.name,
                    side: .buy, requestDate: point.date, effectiveDate: point.date,
                    quantity: quantity, nav: point.nav, amount: plan.amount, fee: fee,
                    realizedPnL: 0, status: .confirmed, isBackfill: false,
                    dividendMode: nil, linkedCash: false, isAutomaticDCA: true, dcaPlanID: plan.id))
                data.cashFlows.append(CashFlow(date: parseDay(point.date) ?? .now, amount: plan.amount,
                    memo: "定投外部投入 · \(plan.name)（用于快照收益调整）", affectsCash: false))
                if let planIndex = data.fundDCAPlans.firstIndex(where: { $0.id == plan.id }) {
                    data.fundDCAPlans[planIndex].processedDates.append(point.date)
                    if data.fundDCAPlans[planIndex].processedDates.count > 2000 {
                        data.fundDCAPlans[planIndex].processedDates.removeFirst(data.fundDCAPlans[planIndex].processedDates.count - 2000)
                    }
                }
                booked += 1
            }
        }
        if booked > 0 {
            refreshTodaySnapshotIfPresent()
            fundDCAStatus = "已按已公布净值补记定投 \(booked) 期；仅更新本机账本"
            save()
        }
        return booked
    }

    private func dcaExecutionPoints(_ history: [FundNAVPoint], plan: FundDCAPlan) -> [FundNAVPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        switch plan.frequency {
        case .daily:
            return history
        case .weekly:
            let grouped = Dictionary(grouping: history) { point -> String in
                guard let date = parseDay(point.date) else { return point.date }
                let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                return "\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
            }
            let startDate = parseDay(plan.startDate)
            return grouped.values.compactMap { points in
                if let startDate, let firstPoint = points.first, let firstDate = parseDay(firstPoint.date) {
                    let startWeek = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startDate)
                    let pointWeek = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: firstDate)
                    let sameWeek = startWeek.yearForWeekOfYear == pointWeek.yearForWeekOfYear
                        && startWeek.weekOfYear == pointWeek.weekOfYear
                    let startWeekday = calendar.component(.weekday, from: startDate)
                    if sameWeek && plan.weekday < startWeekday && !(startWeekday == 1 || startWeekday == 7) { return nil }
                }
                points.sorted { $0.date < $1.date }.first { point in
                    guard let date = parseDay(point.date) else { return false }
                    return calendar.component(.weekday, from: date) >= plan.weekday
                }
            }.sorted { $0.date < $1.date }
        case .biweekly:
            guard let startDate = parseDay(plan.startDate), let lastDate = history.compactMap({ parseDay($0.date) }).max() else { return [] }
            let sortedHistory = history.sorted { $0.date < $1.date }
            var result: [FundNAVPoint] = []
            var due = calendar.startOfDay(for: startDate)
            var lastSelected = ""
            while due <= lastDate {
                let dueString = dayString(due)
                if let selected = sortedHistory.first(where: { $0.date >= dueString && $0.date > lastSelected }),
                   let selectedDate = parseDay(selected.date),
                   ((calendar.dateComponents([.day], from: due, to: selectedDate).day) ?? 99) <= 10 {
                    result.append(selected)
                    lastSelected = selected.date
                }
                guard let nextDue = calendar.date(byAdding: .day, value: 14, to: due) else { break }
                due = nextDue
            }
            return result
        case .monthly:
            let grouped = Dictionary(grouping: history) { String($0.date.prefix(7)) }
            return grouped.values.compactMap { points in
                if let firstDate = parseDay(plan.startDate),
                   let firstPoint = points.first,
                   String(plan.startDate.prefix(7)) == String(firstPoint.date.prefix(7)),
                   calendar.component(.day, from: firstDate) > plan.monthDay { return nil }
                let month = points.first.map { String($0.date.prefix(7)) } ?? ""
                let monthDate = parseDay(month + "-01")
                let range = monthDate.flatMap { calendar.range(of: .day, in: .month, for: $0) }
                let targetDay = min(plan.monthDay, range?.count ?? plan.monthDay)
                points.sorted { $0.date < $1.date }.first { point in
                    guard let date = parseDay(point.date) else { return false }
                    return calendar.component(.day, from: date) >= targetDay
                }
            }.sorted { $0.date < $1.date }
        }
    }

    private func parseDay(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    func recordTrade(code: String, kind: Holding.Kind, side: LedgerEntry.Side, quantity: Double, price: Double,
                     fee: Double, linkedCash: Bool, date: Date = .now, settlementDate: Date? = nil,
                     fundRedemptionLots: [FundLotRedemption]? = nil) throws {
        guard quantity > 0, price > 0, fee >= 0, quantity.isFinite, price.isFinite, fee.isFinite,
              let i = data.holdings.firstIndex(where: { $0.code == code && $0.kind == kind }) else { throw StoreError.invalidTrade }
        var h = data.holdings[i]
        let gross = quantity * price
        guard gross.isFinite else { throw StoreError.invalidTrade }
        var realized = 0.0
        switch side {
        case .buy:
            let newQty = h.quantity + quantity
            let totalCost = h.cost * h.quantity + gross + fee
            guard newQty.isFinite, newQty > 0, totalCost.isFinite else { throw StoreError.invalidTrade }
            if linkedCash && data.cash < gross + fee { throw StoreError.insufficientCash }
            h.cost = totalCost / newQty
            h.quantity = newQty
            if linkedCash { data.cash -= gross + fee }
        case .sell:
            guard quantity <= h.quantity + 1e-8 else { throw StoreError.insufficientShares }
            realized = (price - h.cost) * quantity - fee
            guard realized.isFinite else { throw StoreError.invalidTrade }
            if linkedCash {
                let proceeds = gross - fee
                guard proceeds >= 0, (data.cash + proceeds).isFinite else { throw StoreError.invalidTrade }
            }
            h.quantity = max(0, h.quantity - quantity)
            if h.quantity < 1e-8 { h.quantity = 0 }
            if linkedCash { data.cash += gross - fee }
        }
        data.holdings[i] = h
        data.ledger.append(LedgerEntry(date: date, code: code, name: h.name, side: side, quantity: quantity, price: price, fee: fee, realizedPnL: realized, linkedCash: linkedCash, kind: kind))
        if kind == .fund {
            let day = dayString(date)
            let settleDay = dayString(settlementDate ?? date)
            data.fundTransactions.append(FundTransaction(code: code, name: h.name,
                side: side == .buy ? .buy : .sell, requestDate: day,
                effectiveDate: settleDay,
                quantity: quantity, nav: price, amount: gross, fee: fee, realizedPnL: realized,
                status: .confirmed, isBackfill: false, dividendMode: nil, linkedCash: linkedCash,
                redemptionLots: side == .sell ? fundRedemptionLots : nil))
        }
        save()
    }

    func recordSnapshot() {
        let date = dayString(.now)
        let snap = PortfolioSnapshot(date: date, total: totalAsset, cash: data.cash, recordedAt: .now)
        if let i = data.snapshots.firstIndex(where: { $0.date == date }) { data.snapshots[i] = snap }
        else { data.snapshots.append(snap) }
        data.snapshots.sort { $0.date < $1.date }; save()
    }

    func snapshotReturn(from previous: PortfolioSnapshot, to current: PortfolioSnapshot) -> Double {
        let lowerBound = previous.recordedAt ?? dayBoundary(after: previous.date)
        let upperBound = current.recordedAt ?? dayBoundary(after: current.date)
        let netFlow = data.cashFlows.reduce(0.0) { result, flow in
            flow.date > lowerBound && flow.date < upperBound && (flow.external ?? true) ? result + flow.amount : result
        }
        return current.total - previous.total - netFlow
    }

    /// Snapshot-based return for a selected calendar month. The baseline is
    /// the latest snapshot before the month (or the first snapshot in it when
    /// no earlier baseline exists); this deliberately reports the measured
    /// interval instead of inventing values for dates without snapshots.
    func snapshotMonthSummary(_ month: String) -> (start: PortfolioSnapshot, end: PortfolioSnapshot, pnl: Double, complete: Bool)? {
        let sorted = data.snapshots.sorted { $0.date < $1.date }
        let inMonth = sorted.filter { String($0.date.prefix(7)) == month }
        guard let end = inMonth.last else { return nil }
        let prior = sorted.last { $0.date < "\(month)-01" }
        let start = prior ?? inMonth.first
        guard let start, start.date < end.date else { return nil }
        let expectedStart = prior != nil
        return (start, end, snapshotReturn(from: start, to: end), expectedStart)
    }

    var snapshotMonths: [String] {
        Array(Set(data.snapshots.map { String($0.date.prefix(7)) })).sorted(by: >)
    }

    /// Realized ETF/stock returns are exact only for trades recorded in this
    /// ledger. Older untagged entries are intentionally omitted rather than
    /// being guessed to belong to the ETF account.
    func ledgerDailyRealized(month: String) -> [(date: String, profit: Double, trades: Int)] {
        let grouped = Dictionary(grouping: data.ledger.filter {
            $0.kind == .etf && String(dayString($0.date).prefix(7)) == month
        }, by: { dayString($0.date) })
        return grouped.keys.sorted(by: >).map { date in
            let entries = grouped[date] ?? []
            return (date, entries.reduce(0) { $0 + $1.realizedPnL }, entries.count)
        }
    }

    var ledgerMonths: [String] {
        Array(Set(data.ledger.filter { $0.kind == .etf }.map { String(dayString($0.date).prefix(7)) })).sorted(by: >)
    }

    func plannedDCAAmount(next days: Int) -> Double {
        guard days > 0 else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = calendar.startOfDay(for: .now)
        var total = 0.0
        for offset in 1...days {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            let day = calendar.component(.day, from: date)
            let dayString = self.dayString(date)
            for plan in data.fundDCAPlans where plan.enabled && dayString >= plan.startDate {
                let due: Bool
                switch plan.frequency {
                case .daily: due = (2...6).contains(weekday)
                case .weekly: due = weekday == plan.weekday
                case .biweekly:
                    if let planStart = parseDay(plan.startDate) {
                        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: planStart), to: date).day ?? -1
                        due = offset >= 0 && offset % 14 == 0
                    } else { due = false }
                case .monthly: due = day == plan.monthDay
                }
                if due { total += plan.amount }
            }
        }
        return total
    }

    func adjustCash(amount: Double, memo: String) throws {
        let adjustedCash = data.cash + amount
        guard amount.isFinite, amount != 0, adjustedCash.isFinite, adjustedCash >= 0 else { throw StoreError.invalidCashFlow }
        data.cash = adjustedCash
        data.cashFlows.append(CashFlow(amount: amount, memo: memo.trimmingCharacters(in: .whitespacesAndNewlines), affectsCash: true))
        save()
    }

    func fundDailyPerformance(month: String) -> [FundDailyPerformance] {
        let codes = Set(data.holdings.filter { $0.kind == .fund }.map(\.code)
            + data.fundTransactions.map(\.code))
        var byDay: [String: (profit: Double, base: Double, codes: Set<String>)] = [:]
        for code in codes {
            var navByDay: [String: Double] = [:]
            data.fundNAVHistory.filter { $0.code == code && $0.nav.isFinite && $0.nav > 0 }
                .forEach { navByDay[$0.date] = $0.nav }
            let dates = navByDay.keys.sorted()
            guard dates.count > 1 else { continue }
            let trades = data.fundTransactions.filter { $0.code == code && $0.status == .confirmed }
                .sorted {
                    $0.effectiveDate == $1.effectiveDate
                        ? fundTransactionOrder($0.side) < fundTransactionOrder($1.side)
                        : $0.effectiveDate < $1.effectiveDate
                }
            let events = trades.map { (date: fundEventDate($0), trade: $0) }.sorted { $0.date < $1.date }
            var tradeIndex = 0
            var eventIndex = 0
            var sharesBeforeDate = 0.0
            for idx in 1..<dates.count {
                let previousDate = dates[idx - 1], date = dates[idx]
                while tradeIndex < trades.count && trades[tradeIndex].effectiveDate <= previousDate {
                    let trade = trades[tradeIndex]
                    switch trade.side {
                    case .buy: sharesBeforeDate += trade.quantity
                    case .sell: sharesBeforeDate -= trade.quantity
                    case .dividend where trade.dividendMode == .reinvest: sharesBeforeDate += trade.quantity
                    case .dividend: break
                    }
                    tradeIndex += 1
                }
                guard date.hasPrefix(month), let previousNAV = navByDay[previousDate],
                      let currentNAV = navByDay[date] else { continue }
                var dayTrades: [FundTransaction] = []
                while eventIndex < events.count && events[eventIndex].date <= date {
                    if events[eventIndex].date > previousDate { dayTrades.append(events[eventIndex].trade) }
                    eventIndex += 1
                }
                let distributions = dayTrades.reduce(0.0) { sum, trade in
                    trade.side == .dividend ? sum + trade.amount : sum
                }
                let fees = dayTrades.reduce(0.0) { sum, trade in trade.side == .dividend ? sum : sum + trade.fee }
                let shares = max(0, sharesBeforeDate.isFinite ? sharesBeforeDate : 0)
                guard shares > 0 || distributions != 0 || fees != 0 else { continue }
                let base = previousNAV * shares
                let change = (currentNAV - previousNAV) * shares + distributions - fees
                guard base.isFinite, change.isFinite else { continue }
                var row = byDay[date] ?? (0, 0, [])
                row.profit += change; row.base += base; row.codes.insert(code)
                byDay[date] = row
            }
        }
        return byDay.keys.sorted().compactMap { date in
            guard let row = byDay[date] else { return nil }
            return FundDailyPerformance(date: date, profit: row.profit, baseValue: row.base, fundCount: row.codes.count)
        }
    }

    func inferredBackfillShares(for holding: Holding) -> Double {
        let sold = data.fundTransactions.filter {
            $0.code == holding.code && $0.side == .sell && $0.status == .confirmed
        }.reduce(0.0) { $0 + $1.quantity }
        let reinvested = data.fundTransactions.filter {
            $0.code == holding.code && $0.side == .dividend && $0.dividendMode == .reinvest && $0.status == .confirmed
        }.reduce(0.0) { $0 + $1.quantity }
        return max(0, holding.quantity + sold - reinvested)
    }

    func recordFundBackfill(code: String, date: Date, quantity: Double) throws {
        guard quantity.isFinite, quantity > 0,
              let holding = data.holdings.first(where: { $0.code == code && $0.kind == .fund }),
              !data.fundTransactions.contains(where: { $0.code == code && $0.side == .buy }),
              abs(quantity - inferredBackfillShares(for: holding)) <= 0.01 else {
            throw StoreError.invalidFundBackfill
        }
        let day = dayString(date)
        guard day <= dayString(.now), !data.fundTransactions.contains(where: {
            $0.code == code && $0.side == .sell && $0.effectiveDate < day
        }) else { throw StoreError.invalidFundBackfill }
        data.fundTransactions.append(FundTransaction(code: code, name: holding.name,
            side: .buy, requestDate: day, effectiveDate: day, quantity: quantity,
            nav: 0, amount: 0, fee: 0, realizedPnL: 0, status: .confirmed,
            isBackfill: true, dividendMode: nil, linkedCash: false))
        save()
    }

    func recordFundDividend(code: String, date: Date, amount: Double,
                            mode: FundTransaction.DividendMode, nav: Double,
                            linkCash: Bool) throws {
        guard amount.isFinite, amount > 0,
              let index = data.holdings.firstIndex(where: { $0.code == code && $0.kind == .fund }) else {
            throw StoreError.invalidDividend
        }
        var holding = data.holdings[index]
        var shares = 0.0
        if mode == .reinvest {
            guard nav.isFinite, nav > 0 else { throw StoreError.invalidDividend }
            shares = amount / nav
            let newQuantity = holding.quantity + shares
            let newCost = holding.quantity * holding.cost + amount
            guard shares.isFinite, shares > 0, newQuantity.isFinite, newCost.isFinite else {
                throw StoreError.invalidDividend
            }
            holding.quantity = newQuantity
            holding.cost = newCost / newQuantity
            holding.current = nav
            data.holdings[index] = holding
        } else if linkCash {
            guard (data.cash + amount).isFinite else { throw StoreError.invalidCashFlow }
            data.cash += amount
        }
        let day = dayString(date)
        data.fundTransactions.append(FundTransaction(code: code, name: holding.name,
            side: .dividend, requestDate: day, effectiveDate: day,
            quantity: shares, nav: nav, amount: amount, fee: 0, realizedPnL: 0,
            status: .confirmed, isBackfill: false, dividendMode: mode, linkedCash: linkCash))
        save()
    }

    private func fundTransactionOrder(_ side: FundTransaction.Side) -> Int {
        switch side { case .buy, .dividend: return 0; case .sell: return 1 }
    }

    private func fundEventDate(_ trade: FundTransaction) -> String {
        trade.side == .buy ? trade.requestDate : trade.effectiveDate
    }

    private func dayString(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func dayBoundary(after day: String) -> Date {
        guard let parsed = parseDay(day) else { return .distantPast }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.date(byAdding: .day, value: 1, to: parsed) ?? .distantFuture
    }

    func replaceData(_ imported: PortfolioData, intradayBars: [IntradayBar]? = nil, dailyBars: [DailyBar]? = nil) {
        data = imported
        if let intradayBars { self.intradayBars = intradayBars }
        if let dailyBars { self.dailyBars = Dictionary(grouping: dailyBars, by: \.code).mapValues { $0.sorted { $0.date < $1.date } } }
        saveDailyBars()
        saveIntradayBars(); save()
    }
}

enum StoreError: LocalizedError {
    case invalidTrade, insufficientShares, insufficientCash, invalidCashFlow, invalidFundBackfill, invalidDividend, invalidAlert, invalidFundFeePolicy, invalidAllocationTarget, invalidImportedLedger
    var errorDescription: String? {
        switch self {
        case .invalidTrade: return "请检查份额、价格、费用和标的。"
        case .insufficientShares: return "卖出份额不能超过当前持仓。"
        case .insufficientCash: return "参考现金不足，不能记录这笔现金联动买入。"
        case .invalidCashFlow: return "现金流金额无效，或转出金额超过当前参考现金。"
        case .invalidFundBackfill: return "无法补录：基金不存在、份额无效，或已有买入流水。"
        case .invalidDividend: return "分红金额、净值或基金持仓无效。"
        case .invalidAlert: return "提醒代码或目标价格无效。"
        case .invalidFundFeePolicy: return "费率档位无效：请设置从 0 天开始的费率档，天数不能重复，费率须在 0% 到 100% 之间。"
        case .invalidAllocationTarget: return "目标仓位需在 0% 到 100% 之间。"
        case .invalidImportedLedger: return "无法安全计算成交流水：请导入包含完整买入起点的历史记录，并检查卖出数量是否超过此前买入。"
        }
    }
}
