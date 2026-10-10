import Foundation
import CoreFoundation
import Security

enum AIAnalysisError: LocalizedError {
    case missingKey
    case invalidEndpoint
    case keychain(OSStatus)
    case server(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "请先填写并保存 API 密钥。"
        case .invalidEndpoint: return "接口地址无效。请填写 HTTPS 的兼容接口基础地址。"
        case .keychain(let status): return "密钥无法安全保存（Keychain 错误 \(status)）。"
        case .server(let message): return "分析接口返回错误：\(message)"
        case .emptyResponse: return "接口没有返回可显示的分析内容。"
        }
    }
}

enum AIAnalysisService {
    private static let keychainService = "com.guanpan.pro.native.ai"
    private static let keychainAccount = "api-key"

    static var hasSavedAPIKey: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func saveAPIKey(_ token: String) throws {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        guard !clean.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(clean.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AIAnalysisError.keychain(status) }
    }

    private static func loadAPIKey() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw AIAnalysisError.missingKey
        }
        return token
    }

    static func analyze(config: AIAnalysisConfig, portfolio: PortfolioData) async throws -> String {
        let token = try loadAPIKey()
        let base = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: base), baseURL.scheme?.lowercased() == "https", baseURL.host != nil else {
            throw AIAnalysisError.invalidEndpoint
        }
        let target = base.lowercased().hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: target), !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIAnalysisError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "stream": false,
            "messages": [
                ["role": "system", "content": config.systemPrompt.isEmpty ? AIAnalysisConfig().systemPrompt : config.systemPrompt],
                ["role": "user", "content": portfolioPrompt(portfolio)]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIAnalysisError.server("无法读取 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            let error = payload?["error"] as? [String: Any]
            throw AIAnalysisError.server((error?["message"] as? String) ?? "HTTP \(http.statusCode)")
        }
        let payload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let choices = payload?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content, !content.isEmpty else { throw AIAnalysisError.emptyResponse }
        return content
    }

    private static func portfolioPrompt(_ data: PortfolioData) -> String {
        let fmt: (Double) -> String = { String(format: "%.2f", $0) }
        let holdings = data.holdings.map { h in
            "- \(h.name)（\(h.code)，\(h.kind == .fund ? "场外基金" : "ETF/证券"）：份额 \(fmt(h.quantity))，成本 \(fmt(h.cost))，现价/净值 \(fmt(h.current))，市值 \(fmt(h.marketValue))，浮动盈亏 \(fmt(h.pnl))）"
        }.joined(separator: "\n")
        let quotes = data.quotes.map { q in
            "- \(q.name)（\(q.code)）：\(fmt(q.price))，涨跌 \(String(format: "%.2f", q.changePct * 100))%，更新时间 \(q.updatedAt?.formatted() ?? "未知")"
        }.joined(separator: "\n")
        let snapshots = data.snapshots.sorted { $0.date < $1.date }.suffix(20).map {
            "\($0.date): 总资产 \(fmt($0.total))，现金 \(fmt($0.cash))"
        }.joined(separator: "\n")
        let p = data.investmentProfile
        let style = ["day": "超短线", "swing": "波段", "mid": "中线", "long": "长线定投"][p.style] ?? p.style
        let risk = ["con": "保守", "bal": "平衡", "agg": "激进"][p.risk] ?? p.risk
        let profile = "交易风格：\(style)；风险偏好：\(risk)；典型持有周期：\(p.horizon)；单标的仓位上限：\(fmt(p.maxPositionPercent))%；ETF 溢价敏感：\(p.premiumSensitive ? "是" : "否")；偏好：\(p.preference.isEmpty ? "未填写" : p.preference)；忌讳：\(p.avoid.isEmpty ? "未填写" : p.avoid)；交易方式：\(p.method.isEmpty ? "未填写" : p.method)；目标：\(p.goal.isEmpty ? "未填写" : p.goal)"
        return "请分析以下观盘账户数据，按‘数据概况、观察到的变化、主要风险、还需核对’分段回答。只依据提供的数据；价格可能延迟，净值可能滞后。不要编造技术指标或新闻，也不要声称能确定预测涨跌。\n\n用户自述投资偏好（仅作为分析约束，不代表收益目标可实现）：\n\(profile)\n\n参考现金：\(fmt(data.cash))\n持仓：\n\(holdings.isEmpty ? "（暂无）" : holdings)\n\n自选行情：\n\(quotes.isEmpty ? "（暂无）" : quotes)\n\n最近资产快照：\n\(snapshots.isEmpty ? "（暂无）" : snapshots)"
    }
}
