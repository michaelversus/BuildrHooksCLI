@testable import BuildrHooksCore
import Foundation
import Testing

struct CodexUsageFetcherTests {
    private func executable(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fake-codex")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    @Test func initializationAndFullReadUseOnlySupportedMethods() throws {
        let file = try executable("""
        read -r initialize
        case "$initialize" in *initialize*clientInfo*|*clientInfo*initialize*) ;; *) exit 1;; esac
        echo '{"id":1,"result":{}}'
        read -r initialized
        case "$initialized" in *initialized*) ;; *) exit 1;; esac
        read -r account
        case "$account" in *account*read*) ;; *) exit 1;; esac
        echo '{"id":2,"result":{"account":{"type":"chatgpt","email":null},"requiresOpenaiAuth":true}}'
        read -r limits
        case "$limits" in *account*rateLimits*read*) ;; *) exit 1;; esac
        echo '{"id":3,"result":{"accountId":null,"rateLimits":{"primary":{"usedPercent":12}}}}'
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let data = try CodexUsageFetcher(executablePath: file.path).fetch(timeout: 2)
        #expect(try CodexUsageParser().windows(from: data).first?.usedPercent == 12)
    }

    @Test func recoveryIdentityReadUsesOptionalRoutingIdentityWithoutReadingLimits() throws {
        for routing in ["null", #"{"chatgptAccountId":"account-A"}"#] {
            let file = try executable("""
            read -r initialize
            echo '{"id":1,"result":{}}'
            read -r initialized
            read -r account
            case "$account" in *rateLimits*) exit 1;; *account*read*) ;; *) exit 1;; esac
            printf '%s%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt",' \\
                '"email":"private@example.com"},"workspaceRouting":\(routing)}}'
            """)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let identity = try CodexUsageFetcher(executablePath: file.path).currentAccountIdentity(timeout: 2)
            #expect(identity == (routing == "null" ? nil : "account-A"))
        }
    }

    @Test func persistentConnectionReadsIdleAndInFlightEventsAndReconnects() throws {
        let file = try executable("""
        read -r initialize
        echo '{"id":1,"result":{}}'
        read -r initialized
        read -r account
        echo '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        read -r limits
        echo '{"method":"account/rateLimits/updated","params":{"usedPercent":99}}'
        echo '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}'
        echo '{"method":"account/updated","params":{"secret":"never published"}}'
        read -r account
        echo '{"id":4,"result":{"account":{"type":"chatgpt"}}}'
        read -r limits
        echo '{"id":5,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}'
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let fetcher = CodexUsageFetcher(executablePath: file.path)
        fetcher.beginWatch()
        defer { fetcher.close() }
        let first = try fetcher.fetch(timeout: 2)
        #expect(try CodexUsageParser().windows(from: first).first?.usedPercent == 12)
        let events = try fetcher.events()
        #expect(events.contains(.limitsChanged))
        let second = try fetcher.fetch(timeout: 2)
        #expect(first == second)
        // The fixture ends its connection. A failed full read discards it, allowing reconnect.
        #expect(throws: (any Error).self) { try fetcher.fetch(timeout: 2) }
        let reconnected = try fetcher.fetch(timeout: 2)
        #expect(first == reconnected)
    }

    @Test func cancellationInterruptsOwnedHungFetch() throws {
        let file = try executable("read -r initialize\nexec /bin/sleep 10\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let start = ProcessInfo.processInfo.systemUptime
        let fetcher = CodexUsageFetcher(executablePath: file.path)
        do {
            _ = try fetcher.fetch(timeout: 30, isCancelled: {
                ProcessInfo.processInfo.systemUptime - start >= 0.05
            })
            Issue.record("Expected cancellation")
        } catch UsageFetchError.cancelled {} catch { Issue.record("Unexpected sanitized failure") }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test func providerAuthenticationAndThrottlingErrorsAreSanitized() throws {
        for code in [401, 429] {
            let file = try executable("""
            read -r initialize
            echo '{"id":1,"result":{}}'
            read -r initialized
            read -r account
            echo '{"id":2,"result":{"account":{"type":"chatgpt"},"requiresOpenaiAuth":true}}'
            read -r limits
            printf '%s' '{"id":3,"error":{"code":\(code),"message":"secret-token@example.com/private/path",'
            printf '%s\n' '"data":{"retryAfterSeconds":300}}}'
            """)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            do {
                _ = try CodexUsageFetcher(executablePath: file.path).fetch(timeout: 2)
                Issue.record("Expected provider failure")
            } catch UsageFetchError.authenticationRequired {
                #expect(code == 401)
            } catch let UsageFetchError.throttled(retryAt) {
                #expect(code == 429)
                #expect(try #require(retryAt) > Int64(Date().timeIntervalSince1970 * 1000))
            } catch { Issue.record("Unexpected sanitized failure") }
        }
    }

    @Test func hangingOwnedProcessHasBoundedTimeout() throws {
        let file = try executable("read -r initialize\nexec /bin/sleep 10\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try CodexUsageFetcher(executablePath: file.path).fetch(timeout: 0.05)
            Issue.record("Expected bounded timeout")
        } catch UsageFetchError.timeout {} catch { Issue.record("Unexpected sanitized failure") }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test func missingAndRelativeExecutablesFailWithoutLeakingPaths() {
        for path in ["relative-codex", "/missing-secret-account/codex"] {
            #expect(throws: (any Error).self) { try CodexUsageFetcher(executablePath: path).fetch(timeout: 1) }
        }
    }
}
