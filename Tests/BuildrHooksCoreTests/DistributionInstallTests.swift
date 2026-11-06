import Foundation
import Testing

struct DistributionInstallTests {
    @Test func sourceInstallAndUninstallCarryBothResourceBundles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appending(path: ".build/release")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: repository.appending(path: "Makefile"),
                                         to: root.appending(path: "Makefile"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: release.appending(path: "BuildrHooksCLI"))
        let bundles = ["BuildrHooksCLI_BuildrHooksCLI.bundle", "BuildrHooksCLI_BuildrBridgeContracts.bundle"]
        for bundle in bundles {
            let url = release.appending(path: bundle)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("resource".utf8).write(to: url.appending(path: "fixture"))
        }
        let prefix = root.appending(path: "installed prefix")
        try make(["-o", "build", "install", "prefix=\(prefix.path)"], in: root)
        #expect(FileManager.default.isExecutableFile(atPath: prefix.appending(path: "bin/buildrhooks").path))
        for bundle in bundles {
            #expect(FileManager.default.fileExists(atPath: prefix.appending(path: "bin/\(bundle)/fixture").path))
        }
        try make(["uninstall", "prefix=\(prefix.path)"], in: root)
        #expect(!FileManager.default.fileExists(atPath: prefix.appending(path: "bin/buildrhooks").path))
        for bundle in bundles {
            #expect(!FileManager.default.fileExists(atPath: prefix.appending(path: "bin/\(bundle)").path))
        }
    }

    private func make(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
