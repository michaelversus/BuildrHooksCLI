import Darwin
import Foundation

/// Private setup state; a configuration root is a setup scope, never an account.
struct ClaudeStatusLineOwnership: Codable {
    var original: Data?
    var installed: Data
    var runnerPath: String
}

enum ClaudeStatusLineError: Error, Equatable, CustomStringConvertible {
    case invalidSettings, detached, concurrentEdit, managed, unsafePath, alreadyWrapped
    var description: String {
        switch self {
        case .invalidSettings: "Unsupported Claude settings or statusLine value; no changes applied."
        case .detached: "Status line is detached or repair-needed. Preview setup --repair before applying."
        case .alreadyWrapped:
            "Existing status-line wrapper was edited or detached; replace its command before repair. "
                + "No nesting applied."
        case .concurrentEdit: "Settings changed during setup; no settings were overwritten. Preview again."
        case .managed: "Managed statusLine configuration takes precedence; no changes applied."
        case .unsafePath: "Setup requires ordinary user-owned configuration files and directories."
        }
    }
}

struct ClaudeStatusLineSettings {
    let root: URL
    let settingsURL: URL
    let managedURLs: [URL]
    var beforeWrite: () throws -> Void = {}
    var directory: URL {
        root.appendingPathComponent(".buildrhooks-statusline")
    }

    var metadataURL: URL {
        directory.appendingPathComponent("ownership.json")
    }

    var runnerURL: URL {
        directory.appendingPathComponent("runner")
    }

    init(root: URL, project: Bool = false, managedURLs: [URL] = []) {
        self.root = root
        settingsURL = root.appendingPathComponent(project ? "settings.local.json" : "settings.json")
        self.managedURLs = managedURLs
    }

    static func selectedRoot(configDirectory: String?, project: String?,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let project {
            return URL(fileURLWithPath: project).appendingPathComponent(".claude")
        }
        return (configDirectory ?? environment["CLAUDE_CONFIG_DIR"]).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
    }

    func read() throws -> (bytes: Data?, object: [String: Any]) {
        try safeFile(settingsURL)
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return (nil, [:]) }
        let data = try Data(contentsOf: settingsURL)
        guard data.count <= 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatusLineError.invalidSettings
        }
        return (data, object)
    }

    func ownership() throws -> ClaudeStatusLineOwnership? {
        try safeFile(metadataURL)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        let data = try Data(contentsOf: metadataURL)
        guard data.count <= 4 * 1024 * 1024 else { throw ClaudeStatusLineError.invalidSettings }
        return try JSONDecoder().decode(ClaudeStatusLineOwnership.self, from: data)
    }

    func checkManaged() throws {
        for url in managedURLs where FileManager.default.fileExists(atPath: url.path) {
            guard let object = try JSONSerialization
                .jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw ClaudeStatusLineError.managed
            }
            if object["statusLine"] != nil {
                throw ClaudeStatusLineError.managed
            }
        }
    }

    func write(_ object: [String: Any], expected: Data?) throws {
        try beforeWrite()
        try checkManaged()
        guard try read().bytes == expected else { throw ClaudeStatusLineError.concurrentEdit }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    func prepareDirectory() throws {
        try safeDirectory(root)
        try safeDirectory(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func safeFile(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
                throw ClaudeStatusLineError.unsafePath
            }
        } else if errno != ENOENT {
            throw ClaudeStatusLineError.unsafePath
        }
    }

    private func safeDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
                throw ClaudeStatusLineError.unsafePath
            }
        } else if errno != ENOENT {
            throw ClaudeStatusLineError.unsafePath
        }
    }
}

extension ClaudeStatusLineSettings {
    static func value(_ value: Any?) throws -> Data? {
        try value.map { try JSONSerialization.data(
            withJSONObject: $0,
            options: [.sortedKeys, .fragmentsAllowed]
        ) }
    }

    static func object(_ value: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed)
    }

    static func command(_ value: Data?) throws -> String? {
        guard let value else { return nil }
        if try object(value) is NSNull {
            return nil
        }
        guard let object = try object(value) as? [String: Any], object["type"] as? String == "command",
              let command = object["command"] as? String, !command.isEmpty else {
            throw ClaudeStatusLineError.invalidSettings
        }
        return command
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
