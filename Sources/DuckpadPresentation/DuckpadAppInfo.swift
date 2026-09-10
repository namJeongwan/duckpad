import DuckpadLocalization
import Foundation
import DuckpadDomain

public struct DuckpadAppInfo: Sendable {
    public let version: SemanticVersion?
    public let build: String?

    public init(version: String?, build: String?) {
        self.version = version.flatMap(AppRelease.parseVersion)
        self.build = build
    }

    public static var current: Self {
        Self(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    public var versionDescription: String {
        guard let version else { return L10n.text("Development build") }
        return L10n.text("Version %1$@", L10n.argument(version)) + (build.map { " (\($0))" } ?? "")
    }

    public var diagnosticDescription: String {
        "Duckpad\n\(versionDescription)\n\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
