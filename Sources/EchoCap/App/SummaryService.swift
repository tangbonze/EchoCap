import Foundation
import EchoCapCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a transcript into a short summary, either with the on-device language
/// model or with a cloud endpoint the user configured.
enum SummaryService {

    enum Availability: Equatable {
        case ready
        case unavailable(String)

        var canSummarise: Bool { self == .ready }
    }

    /// Whether the chosen engine can summarise right now.
    static func availability(engine: ModelEngine, cloud: CloudLLMConfig) -> Availability {
        switch engine {
        case .cloud:
            return cloud.isConfigured
                ? .ready
                : .unavailable("云端模型还没配置（设置里填接口地址、API Key 和模型名）")
        case .local:
            return localAvailability
        }
    }

    /// Whether the on-device model can be used right now.
    private static var localAvailability: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                return .unavailable(describe(reason))
            @unknown default:
                return .unavailable("系统返回了未知的模型状态")
            }
        }
        #endif
        return .unavailable("这个版本的 macOS 没有端侧语言模型")
    }

    /// Summarise `transcript`. Long transcripts are summarised in chunks.
    static func summarise(
        _ transcript: String,
        engine: ModelEngine,
        cloud: CloudLLMConfig
    ) async throws -> String {
        guard case .ready = availability(engine: engine, cloud: cloud) else {
            throw SummariseError.unavailable(availability(engine: engine, cloud: cloud))
        }

        let chunks = split(transcript)
        guard !chunks.isEmpty else { throw SummariseError.emptyTranscript }

        switch engine {
        case .cloud:
            let client = CloudLLMClient(timeout: 60)
            var parts: [String] = []
            for chunk in chunks {
                let reply = try await client.complete(
                    system: cloudSystemPrompt,
                    user: "请总结这段字幕记录：\n\n\(chunk)",
                    config: cloud
                )
                parts.append(reply)
            }
            return parts.joined(separator: "\n\n")

        case .local:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession(
                    model: SystemLanguageModel.default,
                    instructions: localInstructions
                )
                var parts: [String] = []
                for chunk in chunks {
                    let response = try await session.respond(
                        to: "请总结这段字幕记录：\n\n\(chunk)"
                    )
                    parts.append(
                        response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                return parts.joined(separator: "\n\n")
            }
            #endif
            throw SummariseError.unavailable(localAvailability)
        }
    }

    enum SummariseError: LocalizedError {
        case unavailable(Availability)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .unavailable(.unavailable(let reason)):
                return "摘要模型不可用：\(reason)"
            case .unavailable(.ready):
                return "摘要模型不可用"
            case .emptyTranscript:
                return "没有可以总结的内容"
            }
        }
    }

    // MARK: - Prompts

    private static let localInstructions = """
        你是一个会议记录助手。用户会给你一段实时字幕记录，请整理成摘要。
        要求：
        - 用简洁的中文输出，专有名词保留原文
        - 先给 3 到 6 条要点，每条一行，以「- 」开头
        - 如果记录里出现了明确的任务、决定或结论，在最后加一个「待办」小节
        - 只使用记录里出现的信息，不要补充、不要推测
        """

    private static let cloudSystemPrompt = """
        你是一个会议记录助手。用户会给你一段实时字幕记录，请整理成摘要。
        要求：
        - 用简洁的中文输出，专有名词保留原文
        - 先给 3 到 6 条要点，每条一行，以「- 」开头
        - 如果记录里出现了明确的任务、决定或结论，在最后加一个「待办」小节
        - 只使用记录里出现的信息，不要补充、不要推测
        """

    // MARK: - Helpers

    /// Split a transcript into pieces small enough for one prompt.
    private static func split(_ text: String, limit: Int = 7000) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [trimmed] }

        var chunks: [String] = []
        var current = ""
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current)
        }
        // Do not let one enormous session run for minutes.
        return Array(chunks.prefix(8))
    }

    private static func describe(_ reason: Any) -> String {
        // The reason type is not public API on every SDK, so describe it rather
        // than match on cases that may not exist.
        let text = String(describing: reason)
        if text.contains("deviceNotEligible") {
            return "这台 Mac 不满足 Apple 智能的硬件或区域条件"
        }
        if text.contains("notEnabled") || text.contains("NotEnabled") {
            return "Apple 智能没有打开，可在「系统设置 → Apple 智能与 Siri」里开启"
        }
        if text.contains("modelNotReady") || text.contains("NotReady") {
            return "模型还在下载，稍后再试"
        }
        return text
    }
}
