import Foundation

public struct PromptGateMarkerReader {
    public var fileManager: FileManager
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        decoder = JSONDecoder()
    }

    public func marker(at repositoryRoot: URL) throws -> PromptGateMarker {
        let url = repositoryRoot
            .appending(path: ".buildrai/hooks/prompt-gate.json")
            .standardizedFileURL

        guard fileManager.fileExists(atPath: url.path) else {
            throw PromptGateExit(
                code: .unavailable,
                message: """
                Prompt Gate is not enabled for this repository. \
                Enable it in BuildrAI before using #BuildrAI-Eval.
                """
            )
        }

        do {
            let data = try Data(contentsOf: url)
            let marker = try decoder.decode(PromptGateMarker.self, from: data)
            guard marker.version == 1 else {
                throw PromptGateExit(
                    code: .invalidConfiguration,
                    message: "Prompt Gate configuration is invalid: unsupported marker version."
                )
            }
            guard marker.enabled else {
                throw PromptGateExit(
                    code: .unavailable,
                    message: """
                    Prompt Gate is disabled for this repository. \
                    Enable it in BuildrAI before using #BuildrAI-Eval.
                    """
                )
            }
            return marker
        } catch let exit as PromptGateExit {
            throw exit
        } catch {
            throw PromptGateExit(
                code: .invalidConfiguration,
                message: "Prompt Gate configuration is invalid: \(error.localizedDescription)"
            )
        }
    }
}
