import Foundation
import ServiceManagement

public enum BackgroundApprovalStatus: String, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

public struct BackgroundApprovalService: Sendable {
    public init() {}

    public func status(forLegacyPlistAt url: URL) -> BackgroundApprovalStatus {
        switch SMAppService.statusForLegacyPlist(at: url) {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    @MainActor
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
