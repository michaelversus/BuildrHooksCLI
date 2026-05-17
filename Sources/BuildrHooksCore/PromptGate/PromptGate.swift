import Foundation

public struct PromptGate {
    public var parser: PromptGateTagParser
    public var markerReader: PromptGateMarkerReader
    public var bridge: PromptGateFileBridge
    public var hookOutputWriter: @Sendable (String) -> Void
    public var now: @Sendable () -> Date
    public var makeRequestID: @Sendable () -> UUID
    public var sleep: @Sendable (TimeInterval) -> Void
    public var timeout: TimeInterval
    public var pollingInterval: TimeInterval
    public var promptCharacterLimit: Int

    public init(
        parser: PromptGateTagParser = .init(),
        markerReader: PromptGateMarkerReader = .init(),
        bridge: PromptGateFileBridge = .init(),
        hookOutputWriter: @escaping @Sendable (String) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init,
        makeRequestID: @escaping @Sendable () -> UUID = UUID.init,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        timeout: TimeInterval = 24.0,
        pollingInterval: TimeInterval = 0.1,
        promptCharacterLimit: Int = 6000
    ) {
        self.parser = parser
        self.markerReader = markerReader
        self.bridge = bridge
        self.hookOutputWriter = hookOutputWriter
        self.now = now
        self.makeRequestID = makeRequestID
        self.sleep = sleep
        self.timeout = timeout
        self.pollingInterval = pollingInterval
        self.promptCharacterLimit = promptCharacterLimit
    }

    @discardableResult
    public func evaluateIfTagged(
        payload: ParsedCodexHookPayload,
        repositoryRoot: URL
    ) throws -> Bool {
        guard let prompt = payload.prompt else {
            return false
        }

        let taggedPrompt: PromptGateTaggedPrompt?
        do {
            taggedPrompt = try parser.parse(prompt)
        } catch {
            throw PromptGateExit(
                code: .protocolError,
                message: error.localizedDescription
            )
        }

        guard let taggedPrompt else {
            return false
        }

        guard taggedPrompt.evaluationPrompt.count <= promptCharacterLimit else {
            throw PromptGateExit(
                code: .promptTooLarge,
                message: "Prompt Gate evaluation prompt is too large. Limit is \(promptCharacterLimit) characters."
            )
        }

        let requestID = makeRequestID().uuidString.lowercased()
        let createdAt = now()
        let request = try makeRequest(
            taggedPrompt: taggedPrompt,
            payload: payload,
            repositoryRoot: repositoryRoot,
            requestID: requestID,
            createdAt: createdAt
        )

        let paths = try bridge.acquireLock(requestID: requestID, repositoryRoot: repositoryRoot, createdAt: createdAt)
        do {
            try bridge.writeRequest(request, paths: paths)
            try waitForDecision(paths: paths, request: request)
            return true
        } catch let exit as PromptGateExit {
            bridge.cleanOwnedFiles(paths: paths, requestID: requestID)
            throw exit
        } catch {
            bridge.cleanOwnedFiles(paths: paths, requestID: requestID)
            throw PromptGateExit(
                code: .protocolError,
                message: "Prompt Gate protocol error: \(error.localizedDescription)"
            )
        }
    }

    private func makeRequest(
        taggedPrompt: PromptGateTaggedPrompt,
        payload: ParsedCodexHookPayload,
        repositoryRoot: URL,
        requestID: String,
        createdAt: Date
    ) throws -> PromptGateRequest {
        let marker = try markerReader.marker(at: repositoryRoot)
        return PromptGateRequest(
            version: 1,
            requestID: requestID,
            createdAt: createdAt,
            deadlineAt: createdAt.addingTimeInterval(timeout),
            source: "buildrhookscli.codex.prompt-submit",
            repoPath: repositoryRoot.path,
            projectID: marker.projectID,
            sessionID: payload.sessionID,
            transcriptPath: payload.transcriptPath,
            model: payload.model,
            originalPrompt: taggedPrompt.originalPrompt,
            evaluationPrompt: taggedPrompt.evaluationPrompt,
            promptCharacterCount: taggedPrompt.evaluationPrompt.count,
            promptCharacterLimit: promptCharacterLimit
        )
    }

    private func waitForDecision(paths: PromptGateFileBridge.Paths, request: PromptGateRequest) throws {
        while now() < request.deadlineAt {
            if let response = try bridge.readResponse(paths: paths) {
                try validate(response: response, requestID: request.requestID)
                bridge.cleanOwnedFiles(paths: paths, requestID: request.requestID)

                switch response.decision {
                case .allow:
                    hookOutputWriter(codexSystemMessageOutput(chatMessage(for: response)))
                    return
                case .deny:
                    throw PromptGateExit(code: .denied, message: chatMessage(for: response))
                }
            }
            sleep(min(pollingInterval, max(0, request.deadlineAt.timeIntervalSince(now()))))
        }

        throw PromptGateExit(
            code: .timeout,
            message: "Prompt Gate timed out waiting for BuildrAI to evaluate this prompt."
        )
    }

    private func validate(response: PromptGateResponse, requestID: String) throws {
        guard response.version == 1 else {
            throw PromptGateExit(
                code: .protocolError,
                message: "Prompt Gate response uses an unsupported protocol version."
            )
        }
        guard response.requestID == requestID else {
            throw PromptGateExit(
                code: .protocolError,
                message: "Prompt Gate response did not match the active request."
            )
        }
        if response.decision == .deny,
           response.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            throw PromptGateExit(
                code: .protocolError,
                message: "Prompt Gate denial response is missing a reason."
            )
        }
    }

    private func codexSystemMessageOutput(_ message: String) -> String {
        let output = CodexHookOutput(systemMessage: message)
        guard let data = try? JSONEncoder().encode(output),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"systemMessage":"✅ Prompt Gate approved this prompt."}"#
        }
        return json
    }

    private func chatMessage(for response: PromptGateResponse) -> String {
        let statusLine = switch response.decision {
        case .allow:
            "✅ Prompt Gate approved this prompt."
        case .deny:
            "⛔ Prompt Gate blocked this prompt."
        }
        let detailLine = "💬 \(chatDescription(for: response))"
        var lines = [statusLine, detailLine]
        if let suggestedPrompt = response.suggestedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggestedPrompt.isEmpty {
            lines.append("Suggested prompt: \(suggestedPrompt)")
        }
        return lines.joined(separator: "\n")
    }

    private func chatDescription(for response: PromptGateResponse) -> String {
        let reason = response.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let reason, !reason.isEmpty {
            parts.append(reason)
        } else {
            parts.append(
                response.decision == .allow ? "BuildrAI found enough detail to continue." : "No reason provided."
            )
        }
        if let score = response.score {
            var scoreDetail = "Score \(score)/100"
            if let label = response.label?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty {
                scoreDetail += " (\(label))"
            }
            if let confidence = response.confidence?.trimmingCharacters(in: .whitespacesAndNewlines),
               !confidence.isEmpty {
                scoreDetail += ", \(confidence) confidence"
            }
            parts.append(scoreDetail)
        }
        if response.decision == .deny,
           let failureCategory = response.failureCategory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !failureCategory.isEmpty {
            parts.append("Category: \(failureCategory)")
        }
        return parts.joined(separator: " ")
    }
}

private struct CodexHookOutput: Encodable {
    let systemMessage: String
}
