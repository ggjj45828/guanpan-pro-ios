import Foundation
import CryptoKit
import Security
import CoreFoundation

struct NativeSyncDocument: Codable {
    var schemaVersion: Int = 1
    var updatedAt: Date = .now
    var data: PortfolioData
    var intradayBars: [IntradayBar]
    var dailyBars: [DailyBar]
}

struct NASSyncResponse: Decodable {
    var ok: Bool?
    var err: String?
    var revision: Int
    var updatedAt: String?
    var data: NativeSyncDocument?
}

enum NASSyncService {
    static let urlKey = "guanpan.native.nas.url"
    static let tokenKey = "guanpan.native.nas.token"
    static let automaticKey = "guanpan.native.nas.automatic"
    static let revisionKey = "guanpan.native.nas.revision"
    static let fingerprintKey = "guanpan.native.nas.fingerprint"

    static func fingerprint(_ document: NativeSyncDocument) throws -> String {
        struct Content: Encodable {
            var data: PortfolioData
            var intradayBars: [IntradayBar]
            var dailyBars: [DailyBar]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let content = Content(data: document.data, intradayBars: document.intradayBars, dailyBars: document.dailyBars)
        let digest = SHA256.hash(data: try encoder.encode(content))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func endpoint(base: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let root = URL(string: trimmed), ["http", "https"].contains(root.scheme?.lowercased() ?? ""), root.host != nil else {
            throw NASSyncError.invalidAddress
        }
        return root.appendingPathComponent("api").appendingPathComponent("native").appendingPathComponent("data")
    }

    static func legacyBackup(base: String, token: String) async throws -> (revision: Int, data: Data?) {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NASSyncError.missingToken }
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: root), ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil else {
            throw NASSyncError.invalidAddress
        }
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("data")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NASSyncError.invalidResponse }
        guard (200...299).contains(http.statusCode),
              let rootObject = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw NASSyncError.server("无法读取 NAS 网页账本（HTTP \(http.statusCode)）")
        }
        if let error = rootObject["err"] as? String { throw NASSyncError.server(error) }
        let payload = rootObject["data"] as? [String: Any]
        let encoded = try payload.map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
        return (rootObject["revision"] as? Int ?? 0, encoded)
    }

    static func request(base: String, token: String, method: String, path: String = "/api/native/data", body: Data? = nil) async throws -> NASSyncResponse {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NASSyncError.missingToken }
        let url: URL
        if path == "/api/native/data" { url = try endpoint(base: base) }
        else {
            let root = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let baseURL = URL(string: root), ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil else { throw NASSyncError.invalidAddress }
            url = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/")
                .reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NASSyncError.invalidResponse }
        let decoded = try? JSONDecoder.nasSync.decode(NASSyncResponse.self, from: bytes)
        if !(200...299).contains(http.statusCode) {
            if http.statusCode == 409 { throw NASSyncError.conflict(decoded?.err ?? "NAS 上的数据已变化") }
            throw NASSyncError.server(decoded?.err ?? "HTTP \(http.statusCode)")
        }
        guard let decoded else { throw NASSyncError.invalidResponse }
        return decoded
    }

    static func get(base: String, token: String) async throws -> NASSyncResponse {
        try await request(base: base, token: token, method: "GET")
    }

    static func ping(base: String, token: String) async throws -> NASSyncResponse {
        try await request(base: base, token: token, method: "GET", path: "/api/native/ping")
    }

    static func put(base: String, token: String, document: NativeSyncDocument,
                    expectedRevision: Int, allowEmptyOverwrite: Bool = false) async throws -> NASSyncResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(Upload(data: document, expectedRevision: expectedRevision,
                                             allowEmptyOverwrite: allowEmptyOverwrite))
        return try await request(base: base, token: token, method: "POST", body: body)
    }

    private struct Upload: Encodable {
        var data: NativeSyncDocument
        var expectedRevision: Int
        var allowEmptyOverwrite: Bool
    }
}

private extension JSONDecoder {
    static var nasSync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum NASSyncError: LocalizedError {
    case invalidAddress, missingToken, invalidResponse
    case conflict(String), server(String)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请填写完整的 NAS 地址，例如 http://192.168.1.20:8787。"
        case .missingToken: return "请填写 NAS 同步口令。"
        case .invalidResponse: return "NAS 返回的数据格式无法识别。"
        case .conflict(let message), .server(let message): return message
        }
    }
}

enum NASCredentialStore {
    private static let service = "com.guanpan.pro.native.nas"
    private static let account = "sync-token"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let bytes = item as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account]
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            let status = SecItemDelete(key as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let update: [String: Any] = [kSecValueData as String: Data(cleaned.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = key
            update.forEach { insert[$0.key] = $0.value }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
