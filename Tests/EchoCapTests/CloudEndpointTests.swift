import Testing
import Foundation
@testable import EchoCapCore

@Suite("云端接口地址")
struct CloudEndpointTests {

    @Test("普通 base URL 补上 /chat/completions")
    func appendsPath() {
        let config = CloudLLMConfig(
            baseURL: "https://api.openai.com/v1",
            apiKey: "k",
            model: "gpt-4o-mini"
        )
        #expect(config.endpoint?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test("结尾多余的斜杠会被去掉")
    func trimsTrailingSlash() {
        let config = CloudLLMConfig(
            baseURL: "https://api.deepseek.com/v1/",
            apiKey: "k",
            model: "deepseek-chat"
        )
        #expect(config.endpoint?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    }

    @Test("已经写了完整路径就不重复追加")
    func keepsFullPath() {
        let config = CloudLLMConfig(
            baseURL: "http://localhost:11434/v1/chat/completions",
            apiKey: "k",
            model: "qwen2.5"
        )
        #expect(config.endpoint?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test("缺任一项就算没配置")
    func configurationRequiresAllThree() {
        #expect(CloudLLMConfig(baseURL: "https://x/v1", apiKey: "k", model: "m").isConfigured)
        #expect(CloudLLMConfig(baseURL: "", apiKey: "k", model: "m").isConfigured == false)
        #expect(CloudLLMConfig(baseURL: "https://x/v1", apiKey: "", model: "m").isConfigured == false)
        #expect(CloudLLMConfig(baseURL: "https://x/v1", apiKey: "k", model: " ").isConfigured == false)
    }

    @Test("空地址没有 endpoint")
    func emptyBaseURLHasNoEndpoint() {
        #expect(CloudLLMConfig(baseURL: "", apiKey: "k", model: "m").endpoint == nil)
    }

    @Test("默认引擎都是本机")
    func enginesDefaultToLocal() {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.translationEngine == .local)
        #expect(settings.summaryEngine == .local)
    }
}
