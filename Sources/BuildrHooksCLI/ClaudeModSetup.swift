import CryptoKit
import Darwin
import Foundation

enum ClaudeModSetupError: Error, CustomStringConvertible {
    case modified
    var description: String {
        "Prepared mod contains edited or unowned files. Nothing changed; choose a new output directory."
    }
}

/// Exports a plugin to an explicitly chosen directory. Claude owns enabling/installing it.
struct ClaudeModSetup {
    let directory: URL
    let assets: URL
    let executable: URL
    private let ownership = ".buildrhooks-mod.json"
    private let files = [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json",
                         "hooks/hooks.json", "hooks/register.js"]

    func setup(apply: Bool) throws -> String {
        try safePath(directory)
        let expected = try existing()
        let preview = "Prepare Buildr usage mod at \(directory.path) using \(executable.path). "
            + "Claude plugin installation/enabling is a separate explicit operator step. "
            + "Preserves terminal status lines, plugins and BuildrAI preferences."
        guard apply else { return preview + " Preview only; repeat with --apply." }
        let lock = try acquireLock()
        defer { Darwin.close(lock) }
        let parent = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw ClaudeStatusLineError.unsafePath
        }
        let staging = parent.appendingPathComponent(".buildr-mod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        var hashes: [String: String] = [:]
        for file in files {
            var data = try Data(contentsOf: assets.appendingPathComponent(file))
            if file == "hooks/register.js" {
                guard let quoted = try String(bytes: JSONEncoder().encode(executable.path), encoding: .utf8),
                      let source = String(data: data, encoding: .utf8) else {
                    throw ClaudeStatusLineError.invalidSettings
                }
                data = Data(source
                    .replacingOccurrences(of: "'__BUILDRHOOKS_EXECUTABLE__'", with: quoted).utf8)
            }
            let target = staging.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: target)
            hashes[file] = hash(data)
        }
        try JSONEncoder().encode(hashes).write(to: staging.appendingPathComponent(ownership))
        guard try existing() == expected else { throw ClaudeStatusLineError.concurrentEdit }
        if expected == nil {
            try FileManager.default.moveItem(at: staging, to: directory)
        } else {
            // Atomic directory exchange keeps an interrupted upgrade usable.
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, directory.path, UInt32(RENAME_SWAP)) == 0 else {
                throw ClaudeStatusLineError.unsafePath
            }
        }
        return preview + " Prepared. Review docs/claude-mod.md before installing in Claude."
    }

    func remove(apply: Bool) throws -> String {
        try safePath(directory)
        guard let expected = try existing() else { return "No prepared Buildr usage mod at \(directory.path)." }
        guard apply else {
            return "Remove owned mod files at \(directory.path). Uninstall in Claude first. "
                + "Preview; repeat with --apply."
        }
        let lock = try acquireLock()
        defer { Darwin.close(lock) }
        guard try existing() == expected else { throw ClaudeStatusLineError.concurrentEdit }
        try FileManager.default.removeItem(at: directory)
        return "Removed prepared mod. Retained quota and terminal status lines are unchanged."
    }

    private func existing() throws -> [String: String]? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let record = directory.appendingPathComponent(ownership)
        try safePath(record)
        let data = try Data(contentsOf: record)
        guard data.count < 8192,
              let hashes = try? JSONDecoder().decode([String: String].self, from: data),
              Set(hashes.keys) == Set(files) else { throw ClaudeModSetupError.modified }
        var found = Set<String>()
        for entry in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(entry)
            try safePath(url)
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                guard ["hooks", ".claude-plugin"].contains(entry) else { throw ClaudeModSetupError.modified }
                continue
            }
            found.insert(entry)
        }
        guard found == Set(files + [ownership]) else { throw ClaudeModSetupError.modified }
        for file in files {
            guard try hash(Data(contentsOf: directory.appendingPathComponent(file))) == hashes[file] else {
                throw ClaudeModSetupError.modified
            }
        }
        return hashes
    }

    private func safePath(_ url: URL) throws {
        // Inspect the leaf before following anything. Parent paths are explicitly
        // selected by the operator and may contain system aliases such as /tmp.
        var leaf = stat()
        if lstat(url.path, &leaf) == 0 {
            guard [S_IFREG, S_IFDIR].contains(leaf.st_mode & S_IFMT), leaf.st_uid == geteuid() else {
                throw ClaudeStatusLineError.unsafePath
            }
        } else if errno != ENOENT {
            throw ClaudeStatusLineError.unsafePath
        }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func acquireLock() throws -> Int32 {
        let path = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent)-buildr-mod.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClaudeStatusLineError.unsafePath }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ClaudeStatusLineError.concurrentEdit
        }
        return descriptor
    }
}
