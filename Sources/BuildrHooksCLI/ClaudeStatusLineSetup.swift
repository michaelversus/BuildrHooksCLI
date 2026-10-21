import Darwin
import Foundation

extension ClaudeStatusLineSettings {
    func setup(apply: Bool, repair: Bool, executable: URL) throws -> String {
        try checkManaged()
        let current = try read()
        let value = try Self.value(current.object["statusLine"])
        let saved = try ownership()
        if let saved, saved.installed == value {
            if apply {
                try refreshRunner(executable, destination: URL(fileURLWithPath: saved.runnerPath))
            }
            return "Status line already installed. Existing delegate and settings preserved. " + Self
                .disclosure
        }
        if let saved, saved.original != value, !repair {
            throw ClaudeStatusLineError.detached
        }
        let command = try Self.command(value)
        let managedPrefix = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "/"
        if let command, command.contains(" claude statusline run --metadata ") {
            let references = [managedPrefix, directory.path + "/"]
                + (saved.map { [$0.runnerPath, Self.quote($0.runnerPath)] } ?? [])
            if references.contains(where: command.contains) {
                throw ClaudeStatusLineError.alreadyWrapped
            }
        }
        let preview = command.map { "Delegate exactly: \($0)\nNo BuildrAI text will be appended." }
            ?? "Synthetic preview: Claude 5h: 75% remaining | weekly: 50% remaining\n"
            + "A custom status line suppresses most default footer keyboard hints."
        guard apply else {
            return preview + "\n" + Self.disclosure
                + "\nPreview only. Repeat setup with --apply" + (repair ? " --repair" : "") + " to install."
        }
        try prepareDirectory()
        try withSetupLock {
            guard try read().bytes == current.bytes else { throw ClaudeStatusLineError.concurrentEdit }
            try install(current: current, prior: value, executable: executable)
        }
        return preview + "\nInstalled for the selected settings scope. " + Self.disclosure
    }

    func remove(apply: Bool) throws -> String {
        try checkManaged()
        let current = try read()
        guard let saved = try ownership() else { return "No managed status line in this scope." }
        let value = try Self.value(current.object["statusLine"])
        if value == saved.original {
            return "Prior statusLine already restored; retained usage preserved."
        }
        guard value == saved.installed else { throw ClaudeStatusLineError.detached }
        guard apply
        else {
            return "Preview: restore the complete prior statusLine value or absence. Repeat remove --apply."
        }
        try withSetupLock {
            var object = current.object
            object["statusLine"] = try saved.original.map(Self.object)
            try write(object, expected: current.bytes)
            // Retain the standalone runner/record for callbacks already launched from old settings.
            // Its original delegate remains usable, and retained usage is not cleared.
        }
        return "Prior statusLine restored. Unrelated settings and retained usage preserved."
    }

    func installationStatus() throws -> String {
        let current = try read()
        guard let saved = try ownership() else { return "Not installed in the selected scope." }
        return try Self.value(current.object["statusLine"]) == saved.installed
            ? "Installed in this scope; effective session use and received quota are separate."
            : "Detached or removed; settings preserved. Explicit setup --repair can adopt after preview."
    }

    static var disclosure: String {
        "Reported by Claude Code sessions; account attribution unavailable. Switching accounts or concurrent sessions "
            + "may report another account. Updated means bridge receipt, not when Claude measured quota. "
            + "Last received is diagnostic receipt time. Project/managed overrides may supersede this scope. "
            + "Recovery requires an already available usage watch/service responder or a new callback; "
            + "no responder means waiting/no response, not proof of missing or incompatible installation. "
            + "Setup does not enable a service, authentication or telemetry."
    }

    private func install(
        current: (bytes: Data?, object: [String: Any]),
        prior: Data?,
        executable: URL
    ) throws {
        let generation = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let runner = generation.appendingPathComponent("runner")
        let callbackMetadata = generation.appendingPathComponent("ownership.json")
        try refreshRunner(executable, destination: runner)
        var installed = (prior.flatMap { try? Self.object($0) } as? [String: Any]) ?? [:]
        installed["type"] = "command"
        installed["command"] = Self.quote(runner.path) + " claude statusline run --metadata "
            + Self.quote(callbackMetadata.path)
        let installedData = try Self.value(installed)!
        let record = ClaudeStatusLineOwnership(
            original: prior,
            installed: installedData,
            runnerPath: runner.path
        )
        let encoded = try JSONEncoder().encode(record)
        try encoded.write(to: callbackMetadata, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: callbackMetadata.path
        )
        try encoded.write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        var object = current.object
        object["statusLine"] = installed
        try write(object, expected: current.bytes)
    }

    private func refreshRunner(_ executable: URL, destination: URL) throws {
        try prepareDirectory()
        try safeFile(destination)
        let data = try Data(contentsOf: executable)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    }

    private func withSetupLock(_ body: () throws -> Void) throws {
        let path = directory.appendingPathComponent("setup.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClaudeStatusLineError.unsafePath }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ClaudeStatusLineError.unsafePath }
        try body()
    }
}
