import Foundation
import Security
import EchoCapCore

enum CloudLLMError: LocalizedError {
    case notConfigured
    case badEndpoint(String)
    case http(Int, String)
    case empty
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "云端模型还没配置（需要在设置里填接口地址、API Key 和模型名）"
        case .badEndpoint(let text):
            return "接口地址无效：\(text)"
        case .http(let code, let body):
            let detail = body.isEmpty ? "" : "：\(body.prefix(200))"
            if code == 401 || code == 403 { return "API Key 被拒绝（HTTP \(code)）\(detail)" }
            if code == 429 { return "请求太频繁或额度用尽（HTTP 429）\(detail)" }
            return "服务返回 HTTP \(code)\(detail)"
        case .empty:
            return "云端返回了空结果"
        case .transport(let message):
            return "网络请求失败：\(message)"
        }
    }
}

/// A minimal OpenAI-compatible chat client.
actor CloudLLMClient {
    private let session: URLSession

    init(timeout: TimeInterval = 25) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
    }

    /// List the models the endpoint offers.
    ///
    /// Used to fill the model pickers, so nobody has to remember that a
    /// provider spells its model `deepseek-chat` and not `deepseek`.
    func models(config: CloudLLMConfig) async throws -> [String] {
        guard !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CloudLLMError.notConfigured
        }
        guard let url = config.modelsEndpoint else {
            throw CloudLLMError.badEndpoint(config.baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudLLMError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CloudLLMError.http(http.statusCode, text)
        }

        let names = CloudModelList.parse(data)
        guard !names.isEmpty else { throw CloudLLMError.empty }
        return names
    }

    /// One system message plus one user message, returning the reply text.
    func complete(
        system: String,
        user: String,
        config: CloudLLMConfig
    ) async throws -> String {
        guard config.isConfigured else { throw CloudLLMError.notConfigured }
        guard let url = config.endpoint else { throw CloudLLMError.badEndpoint(config.baseURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudLLMError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CloudLLMError.http(http.statusCode, text)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty
        else {
            throw CloudLLMError.empty
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The API key lives in the Keychain, not in `UserDefaults`.
enum CloudCredentialStore {
    private static let service = "com.echocap.EchoCap.cloud"

    static func apiKey() -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "apiKey",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    static func setAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "apiKey",
        ]
        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }
}
