import AppKit
import BuildrBridgeContracts
import Foundation

enum ReportAppState { case running, launched, unavailable, failed }

/// Command boundary effects never inspect source catalogs, credentials or app caches.
struct ReportCommandExecution {
    var files = ReportFileSystem()
    var now: () -> Double = { Date().timeIntervalSince1970 }
    var requestID: () -> String = { UUID().uuidString }
    var wait: (Double) throws -> Void = { Thread.sleep(forTimeInterval: $0) }
    var launch: () -> ReportAppState = {
        let identifier = "app.nsbuilder.BuildrAI"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return .unavailable
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            return .running
        }
        return NSWorkspace.shared.open(url) ? .launched : .failed
    }

    var output: (String) -> Void = { print($0) }
    var diagnostic: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    func run(scopePath: String, timeout: Double, body: () throws -> BridgeRequestBody) throws {
        let scope = try JSONDecoder().decode(BridgeScope.self, from: files.readInput(URL(fileURLWithPath: scopePath)))
        try BridgeValidator.validate(scope)
        let started = now()
        let request = try BridgeRequest(version: 1, requestID: requestID(), scope: scope,
                                        createdAt: started, deadline: started + timeout, body: body())
        let response: BridgeResponse
        do {
            // Finalization validation requires the retained packet, loaded under the transport lock.
            if request.body.operation != .finalize {
                try BridgeValidator.validate(request, expectedScope: scope)
            }
            if request.body.operation == .cancel {
                response = try files.cancel(request)
            } else {
                response = try exchange(request, timeout: timeout)
            }
        } catch let error as ReportExchangeError {
            response = .init(version: 1, requestID: request.requestID, scope: scope, body: .error(error.failure))
        } catch let error as BridgeValidationError where error == .incompatibleVersion {
            response = .init(version: 1, requestID: request.requestID, scope: scope,
                             body: .error(.init(code: .incompatibleVersion,
                                                action: "Install a compatible protocol v1 app and CLI.")))
        } catch {
            response = .init(version: 1, requestID: request.requestID, scope: scope,
                             body: .error(.init(code: .invalidInput,
                                                action: "Check v1 input, response identity and project scope.")))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        guard let json = String(data: data, encoding: .utf8) else { throw ReportCommandFailure() }
        output(json)
        if case .error = response.body {
            throw ReportCommandFailure()
        }
    }

    private func validateResponse(_ response: BridgeResponse, for request: BridgeRequest) throws {
        do {
            try BridgeValidator.validate(response, for: request)
        } catch BridgeValidationError.invalidPayload {
            if case let .prepared(packet) = response.body,
               packet.sessions.allSatisfy(\.records.isEmpty) {
                throw ReportExchangeError(
                    .unusableEvidence, "No usable evidence. Review session access or select another session."
                )
            }
            throw BridgeValidationError.invalidPayload
        }
    }

    private func updateWorkflow(_ response: BridgeResponse, handoff: any ReportHandoff) throws {
        switch response.body {
        case let .prepared(packet): try handoff.retain(packet)
        case .discovered, .resolved, .finalized: try handoff.complete()
        case let .error(failure) where [.cancelled, .timeout].contains(failure.code):
            try handoff.terminate(failure.code)
        default: break
        }
    }

    private func checkCancellation(_ handoff: any ReportHandoff) throws {
        do {
            try handoff.checkCancellation()
        } catch let error as ReportExchangeError where error.failure.code == .cancelled {
            try handoff.terminate(.cancelled)
            throw error
        }
    }

    private func openApp() throws {
        switch launch() {
        case .unavailable: throw ReportExchangeError(.appUnavailable, "Install BuildrAI, then retry this report.")
        case .failed: throw ReportExchangeError(.launchFailed, "Open BuildrAI manually and retry this report.")
        case .running, .launched: break
        }
    }

    private func exchange(_ request: BridgeRequest, timeout: Double) throws -> BridgeResponse {
        let handoff = try files.begin(request)
        defer { handoff.close() }
        try checkCancellation(handoff)
        try openApp()
        var previous: BridgeProgress?
        for _ in 0 ..< Int(ceil(timeout / 0.05)) {
            try checkCancellation(handoff)
            guard now() < request.deadline else { break }
            if let response = try handoff.readResponse() {
                try validateResponse(response, for: request)
                try checkCancellation(handoff)
                guard now() < request.deadline else { break }
                if case let .progress(progress) = response.body {
                    if progress != previous {
                        diagnostic("BuildrAI: " + progress.stage.rawValue)
                    }
                    previous = progress
                } else {
                    do {
                        try updateWorkflow(response, handoff: handoff)
                    } catch let error as ReportExchangeError where error.failure.code == .cancelled {
                        try handoff.terminate(.cancelled)
                        throw error
                    }
                    if case .prepared = response.body {
                        try checkCancellation(handoff)
                    }
                    return response
                }
            }
            try wait(min(0.05, max(0, request.deadline - now())))
        }
        try handoff.terminate(.timeout)
        throw ReportExchangeError(.timeout, "BuildrAI did not complete before the deadline. "
            + "Verify app setup and project access, then retry.")
    }
}

struct ReportCommandFailure: Error {}

struct ReportExchangeError: Error {
    let failure: BridgeFailure
    init(_ code: BridgeFailure.Code, _ action: String) {
        failure = .init(code: code, action: action)
    }
}
