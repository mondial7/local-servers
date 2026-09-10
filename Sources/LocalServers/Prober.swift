import Foundation

/// What we learned by actually talking to a port.
struct ProbeResult {
    var scheme: String       // "http" or "https"
    var statusCode: Int
    var title: String?       // <title> of the served page, when it serves HTML
    var kind: String?        // short hint: "HTML", "JSON", "API", ...
}

/// Accepts the self-signed certificates that local dev servers hand out.
private final class LocalTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum Prober {
    private static let delegate = LocalTrustDelegate()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.0
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// Tries http first, then https. Returns nil when the port speaks neither.
    static func probe(port: Int) async -> ProbeResult? {
        for scheme in ["http", "https"] {
            if let result = await request(scheme: scheme, port: port) { return result }
        }
        return nil
    }

    private static func request(scheme: String, port: Int) async -> ProbeResult? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html,*/*", forHTTPHeaderField: "Accept")
        request.setValue("LocalServers/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let body = String(data: data.prefix(64 * 1024), encoding: .utf8) ?? ""

        var kind: String?
        if contentType.contains("json") { kind = "JSON" }
        else if contentType.contains("html") { kind = "HTML" }
        else if !contentType.isEmpty { kind = contentType.split(separator: ";").first.map { String($0).uppercased() } }

        return ProbeResult(scheme: scheme, statusCode: http.statusCode,
                           title: extractTitle(from: body), kind: kind)
    }

    private static func extractTitle(from html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let gt = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive,
                                     range: gt.upperBound..<html.endIndex) else { return nil }
        let title = html[gt.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(80))
    }
}
