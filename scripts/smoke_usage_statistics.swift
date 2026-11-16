// Opt-in live smoke: compile with UsageStatisticsEvent.swift and
// UsageStatisticsTransport.swift, then run --app /absolute/Duckpad.app
// --send-debug-event. Sends exactly one diagnostic event in Debug mode;
// it does not open the app, modify preferences or send Release usage events.
import Foundation

@main
private enum UsageStatisticsSmoke {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, arguments[1] == "--app", arguments[3] == "--send-debug-event",
              arguments[2].hasPrefix("/"), arguments[2].hasSuffix(".app") else {
            print("Usage: smoke-usage-statistics --app /absolute/Duckpad.app --send-debug-event")
            exit(64)
        }
        do {
            let app = URL(fileURLWithPath: arguments[2], isDirectory: true)
            let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let host = info["DuckpadUsageHost"] as? String,
                  let key = info["DuckpadUsageAppKey"] as? String,
                  let version = info["CFBundleShortVersionString"] as? String,
                  let build = info["CFBundleVersion"] as? String,
                  let transport = UsageStatisticsTransport(host: host, appKey: key) else {
                print("FAIL: app usage-statistics configuration is unavailable")
                exit(1)
            }
            let event = UsageStatisticsEvent(timestamp: Date(), sessionId: UUID().uuidString,
                eventName: "deployment_swift_ingestion_check",
                systemProps: .init(isDebug: true, osVersion: "diagnostic", appVersion: version, appBuildNumber: build),
                props: .init(dimension: "transport_smoke", outcome: "success", durationBucket: "none", count: 1))
            let delivery: String
            switch await transport.send([event]) {
            case .sent: delivery = "sent"
            case .retry: delivery = "retry"
            case .discarded: delivery = "discarded"
            }
            // Only diagnostic metadata; never print the app key or request headers.
            let output: [String: Any] = ["delivery": delivery, "mode": "Debug",
                "eventName": event.eventName, "sessionId": event.sessionId, "appVersion": version]
            let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            print(String(decoding: encoded, as: UTF8.self))
            if delivery != "sent" { exit(1) }
        } catch {
            let failure = error as NSError
            print("FAIL: diagnostic \(failure.domain) \(failure.code)")
            exit(1)
        }
    }
}
