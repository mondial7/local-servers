import Foundation

/// What we learned by actually talking to a port.
struct ProbeResult {
    var scheme: String       // "http" or "https"
    var statusCode: Int
    var title: String?       // <title> of the served page, when it serves HTML
    var kind: String?        // short hint: "HTML", "JSON", "API", ...
}

/// Local dev servers hand out self-signed certificates, so probes have to accept
/// them — but only on loopback, and only for the one hop we asked for. Anything
/// else falls back to the system's normal certificate validation.
private final class LoopbackSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let host = space.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.loopbackHosts.contains(host),
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// A probe must never leave this machine: a local port that answers with a
    /// redirect would otherwise steer us into an arbitrary outbound request.
    /// Refusing the redirect still leaves us the 3xx response to report.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum Prober {
    private static let delegate = LoopbackSessionDelegate()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.0
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// Tries http first, then https, against the exact address the process bound.
    /// Returns nil when the port speaks neither.
    static func probe(host: String, port: Int) async -> ProbeResult? {
        for scheme in ["http", "https"] {
            if let result = await request(scheme: scheme, host: host, port: port) { return result }
        }
        return nil
    }

    private static func request(scheme: String, host: String, port: Int) async -> ProbeResult? {
        guard let url = URL(string: "\(scheme)://\(host):\(port)/") else { return nil }
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
        let raw = html[gt.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        return DisplayText.sanitize(raw, limit: 80)
    }
}

/// Every string this app shows comes from a process that chose it — a page
/// <title>, an executable name, an argv entry. Strip the characters that let
/// one of those impersonate something else in the menu.
enum DisplayText {
    private static let disallowed: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.formUnion(CharacterSet(charactersIn: "\u{202A}"..."\u{202E}"))  // bidi overrides
        set.formUnion(CharacterSet(charactersIn: "\u{2066}"..."\u{2069}"))  // bidi isolates
        set.formUnion(CharacterSet(charactersIn: "\u{200B}"..."\u{200F}"))  // zero-width & marks
        set.insert(charactersIn: "\u{FEFF}\u{00AD}\u{2028}\u{2029}")
        return set
    }()

    static func sanitize(_ value: String, limit: Int) -> String? {
        let stripped = String(String.UnicodeScalarView(value.unicodeScalars.filter { !disallowed.contains($0) }))
        let collapsed = stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
