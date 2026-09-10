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
    /// Built from the address we actually probed, so the browser cannot be
    /// sent to a different process than the one this row describes.
    var localURL: URL? { URL(string: "\(scheme)://\(port.address):\(port.port)/") }
    var lanURL: URL? {
        guard port.isExposedToLAN, let ip = NetworkInfo.lanAddress() else { return nil }
        return URL(string: "\(scheme)://\(ip):\(port.port)/")
    }

    /// macOS ships a pile of always-on listeners; they are noise in a dev tool.
    /// The name alone proves nothing — any binary can call itself `trustd` — so
    /// the executable must also live where only root can put it, and a
    /// LAN-exposed port is never hidden on the strength of its name.
    var isSystemService: Bool {
        guard port.isApplePath, !port.isExposedToLAN else { return false }
        let known: Set<String> = [
            "ControlCenter", "rapportd", "sharingd", "AirPlayXPCHelper", "remoted", "launchd",
            "mDNSResponder", "identityservicesd", "apsd", "cloudd", "distnoted", "coreaudiod",
            "netbiosd", "SubmitDiagInfo", "AppleIDSettings", "trustd", "nsurlsessiond",
        ]
        return known.contains(port.command)
    }
}

/// One address+port pair to probe. Ports alone are not unique: IPv4 and IPv6
/// binds of the same number can belong to different processes.
struct ProbeTarget: Hashable {
    var host: String
    var port: Int

    init(_ listening: ListeningPort) {
        host = listening.address
        port = listening.port
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
        let probes = await withTaskGroup(of: (ProbeTarget, ProbeResult?).self) { group -> [ProbeTarget: ProbeResult] in
            // Two processes can hold 127.0.0.1:8080 and [::1]:8080 at once, so a
            // result belongs to an address and port, never to a port alone.
            for target in Set(ports.map(ProbeTarget.init)) {
                group.addTask { (target, await Prober.probe(host: target.host, port: target.port)) }
            }
            var result: [ProbeTarget: ProbeResult] = [:]
            for await (target, probe) in group {
                if let probe { result[target] = probe }
            }
            return result
        }

        entries = ports
            .map { ServerEntry(port: $0, probe: probes[ProbeTarget($0)]) }
            .sorted { lhs, rhs in
                // Pages you can open first, then APIs, then everything else.
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.port.port < rhs.port.port
            }
        lanAddress = ip
        lastRefresh = Date()
    }
}
