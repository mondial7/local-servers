import Foundation
import SwiftUI

struct ServerEntry: Identifiable {
    var port: ListeningPort
    var probe: ProbeResult?

    var id: String { "\(port.pid):\(port.port)" }
    var isWeb: Bool { probe != nil }

    /// Something a browser can actually show: it answered without an error status.
    var isBrowsable: Bool {
        guard let code = probe?.statusCode else { return false }
        return (200..<400).contains(code)
    }

    var displayName: String {
        if let title = probe?.title, !title.isEmpty { return title }
        return port.derivedName
    }

    var scheme: String { probe?.scheme ?? "http" }

    /// Sort weight: HTML pages, then other served content, then dead ends.
    var rank: Int {
        guard isBrowsable else { return isWeb ? 2 : 3 }
        return probe?.kind == "HTML" ? 0 : 1
    }
    var localURL: URL { URL(string: "\(scheme)://localhost:\(port.port)/")! }
    var lanURL: URL? {
        guard port.isExposedToLAN, let ip = NetworkInfo.lanAddress() else { return nil }
        return URL(string: "\(scheme)://\(ip):\(port.port)/")
    }

    /// macOS ships a pile of always-on listeners; they are noise in a dev tool.
    var isSystemService: Bool {
        let known: Set<String> = [
            "ControlCenter", "rapportd", "sharingd", "AirPlayXPCHelper", "remoted", "launchd",
            "mDNSResponder", "identityservicesd", "apsd", "cloudd", "distnoted", "coreaudiod",
            "netbiosd", "SubmitDiagInfo", "AppleIDSettings", "trustd", "nsurlsessiond",
        ]
        return known.contains(port.command)
    }
}

@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var entries: [ServerEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lanAddress: String?
    @Published var showAllPorts: Bool {
        didSet { UserDefaults.standard.set(showAllPorts, forKey: "showAllPorts") }
    }

    init() {
        showAllPorts = UserDefaults.standard.bool(forKey: "showAllPorts")
    }

    var webServers: [ServerEntry] { entries.filter { $0.isBrowsable && !$0.isSystemService } }
    var otherPorts: [ServerEntry] { entries.filter { !$0.isBrowsable || $0.isSystemService } }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let ports = await Task.detached(priority: .userInitiated) { PortScanner.scan() }.value
        let ip = await Task.detached(priority: .utility) { NetworkInfo.lanAddress() }.value

        // Probe every port at once; each has a hard 1.5s timeout.
        let probes = await withTaskGroup(of: (Int, ProbeResult?).self) { group -> [Int: ProbeResult] in
            for port in Set(ports.map(\.port)) {
                group.addTask { (port, await Prober.probe(port: port)) }
            }
            var result: [Int: ProbeResult] = [:]
            for await (port, probe) in group {
                if let probe { result[port] = probe }
            }
            return result
        }

        entries = ports
            .map { ServerEntry(port: $0, probe: probes[$0.port]) }
            .sorted { lhs, rhs in
                // Pages you can open first, then APIs, then everything else.
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.port.port < rhs.port.port
            }
        lanAddress = ip
        lastRefresh = Date()
    }
}
