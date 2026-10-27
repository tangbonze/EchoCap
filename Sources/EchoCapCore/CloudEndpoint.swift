import Foundation

/// Where a cloud model lives and how to talk to it.
///
/// Deliberately the OpenAI chat-completions shape, because that is what almost
/// every provider — OpenAI, DeepSeek, Moonshot, SiliconFlow, a local Ollama or
/// LM Studio — accepts. One field for the endpoint, one for the key, one for
/// the model name.
public struct CloudLLMConfig: Equatable, Sendable {
    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    public var baseURL: String
    public var apiKey: String
    public var model: String

    public var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The chat-completions URL, tolerating a base that already ends in `/v1`.
    public var endpoint: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("/") { text.removeLast() }
        if !text.hasSuffix("/chat/completions") {
            text += "/chat/completions"
        }
        return URL(string: text)
    }
}

