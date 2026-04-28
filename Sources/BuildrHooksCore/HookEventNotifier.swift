import Foundation

public enum HookEventNotification {
    public static let name = Notification.Name("ai.buildrai.hook-event-enqueued")
    public static let repositoryRootKey = "repositoryRootPath"
}

public protocol HookEventNotifying: Sendable {
    func postHookEventEnqueued(repositoryRootPath: String)
}

public struct DistributedHookEventNotifier: HookEventNotifying {
    public init() {}

    public func postHookEventEnqueued(repositoryRootPath: String) {
        DistributedNotificationCenter.default().postNotificationName(
            HookEventNotification.name,
            object: nil,
            userInfo: [HookEventNotification.repositoryRootKey: repositoryRootPath],
            deliverImmediately: true
        )
    }
}
