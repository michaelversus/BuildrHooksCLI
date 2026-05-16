import Foundation

public struct PromptGateTaggedPrompt: Equatable, Sendable {
    public let originalPrompt: String
    public let evaluationPrompt: String
}

public enum PromptGateTagParserError: Error, Equatable, LocalizedError {
    case emptyEvaluationPrompt

    public var errorDescription: String? {
        switch self {
        case .emptyEvaluationPrompt:
            "Prompt Gate evaluation prompt is empty after removing #BuildrAI-Eval."
        }
    }
}

public struct PromptGateTagParser: Sendable {
    public static let controlTag = "#BuildrAI-Eval"

    public init() {}

    public func parse(_ prompt: String) throws -> PromptGateTaggedPrompt? {
        var fenceMarker: String?
        var foundTag = false
        var retainedLines: [Substring] = []
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fenceMarker {
                retainedLines.append(line)
                if trimmed.hasPrefix(marker) {
                    fenceMarker = nil
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenceMarker = String(trimmed.prefix(3))
                retainedLines.append(line)
                continue
            }

            if trimmed == Self.controlTag {
                foundTag = true
                continue
            }

            retainedLines.append(line)
        }

        guard foundTag else {
            return nil
        }

        let evaluationPrompt = retainedLines.joined(separator: "\n")
        guard !evaluationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromptGateTagParserError.emptyEvaluationPrompt
        }

        return PromptGateTaggedPrompt(
            originalPrompt: prompt,
            evaluationPrompt: evaluationPrompt
        )
    }
}
