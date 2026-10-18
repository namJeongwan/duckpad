import Foundation

public enum UsageStatisticsDelivery: Sendable { case sent, retry, discarded }

/// Ephemeral HTTPS delivery: no cookies, credentials, cache, redirects, or UI.
public final class UsageStatisticsTransport: NSObject, URLSessionTaskDelegate, Sendable {
    private let endpoint: URL
    private let appKey: String

    public init?(host: String, appKey: String) {
        guard let url = URL(string: host), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              appKey.range(of: #"^A-SH-[0-9]{10}$"#, options: .regularExpression) != nil else { return nil }
        endpoint = url.appendingPathComponent("api/v0/events")
        self.appKey = appKey
    }

    public func send(_ events: [UsageStatisticsEvent]) async -> UsageStatisticsDelivery {
        guard !Task.isCancelled, !events.isEmpty, events.count <= 25 else { return .discarded }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(events), body.count <= 128 * 1024 else { return .discarded }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appKey, forHTTPHeaderField: "App-Key")
        request.setValue("Duckpad-Usage/1", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        do {
            // Only the status is needed. Do not buffer an unbounded response body.
            let (_, response) = try await session.bytes(for: request)
            guard !Task.isCancelled, let response = response as? HTTPURLResponse else { return .discarded }
            if (200..<300).contains(response.statusCode) { return .sent }
            return response.statusCode == 429 || response.statusCode >= 500 ? .retry : .discarded
        } catch {
            return Task.isCancelled ? .discarded : .retry
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
