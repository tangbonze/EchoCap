import Testing
import Foundation
@testable import EchoCapCore

@Suite("云端模型列表")
struct CloudModelListTests {

    @Test("标准 OpenAI 形状")
    func parsesOpenAIShape() {
        let json = """
        {"object":"list","data":[{"id":"gpt-4o-mini"},{"id":"gpt-4o"},{"id":"o3-mini"}]}
        """.data(using: .utf8)!
        #expect(CloudModelList.parse(json) == ["gpt-4o", "gpt-4o-mini", "o3-mini"])
    }

    @Test("裸数组也能解析")
    func parsesBareArray() {
        let json = """
        [{"id":"qwen2.5"},{"id":"llama3.1"}]
        """.data(using: .utf8)!
        #expect(CloudModelList.parse(json) == ["llama3.1", "qwen2.5"])
    }

    @Test("重复项被去掉并排序")
    func deduplicates() {
        let json = """
        {"data":[{"id":"b"},{"id":"a"},{"id":"b"}]}
        """.data(using: .utf8)!
        #expect(CloudModelList.parse(json) == ["a", "b"])
    }

    @Test("认不出来的返回空，而不是崩溃")
    func unknownShapeIsEmpty() {
        #expect(CloudModelList.parse(Data("not json".utf8)).isEmpty)
        #expect(CloudModelList.parse(Data("{}".utf8)).isEmpty)
        #expect(CloudModelList.parse(Data(#"{"error":"bad key"}"#.utf8)).isEmpty)
    }

    @Test("模型列表地址由接口地址推出")
    func modelsEndpointDerivation() {
        #expect(
            CloudLLMConfig(baseURL: "https://api.openai.com/v1", apiKey: "k", model: "m")
                .modelsEndpoint?.absoluteString == "https://api.openai.com/v1/models"
        )
        #expect(
            CloudLLMConfig(baseURL: "http://localhost:11434/v1/chat/completions", apiKey: "k", model: "m")
                .modelsEndpoint?.absoluteString == "http://localhost:11434/v1/models"
        )
    }
}
