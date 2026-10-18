import Foundation

/// Aptabase's v0 wire schema. Deliberately excludes machine/user identifiers.
public struct UsageStatisticsEvent: Encodable, Sendable {
    public struct SystemProperties: Encodable, Sendable {
        public let isDebug: Bool
        public let osName = "macOS"
        public let osVersion: String
        public let appVersion: String
        public let appBuildNumber: String
        public let sdkVersion = "duckpad-usage@1"
        public init(isDebug: Bool, osVersion: String, appVersion: String, appBuildNumber: String) {
            self.isDebug = isDebug
            self.osVersion = osVersion
            self.appVersion = appVersion
            self.appBuildNumber = appBuildNumber
        }
    }

    public struct Properties: Encodable, Sendable {
        public let dimension: String
        public let outcome: String
        public let durationBucket: String
        public var count: Int
    }

    public let timestamp: Date
    public let sessionId: String
    public let eventName: String
    public let systemProps: SystemProperties
    public var props: Properties
}
