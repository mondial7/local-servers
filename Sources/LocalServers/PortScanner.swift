import Foundation

/// A TCP port that some process on this machine is listening on.
struct ListeningPort: Hashable {
    var port: Int
    var pid: Int32
    var command: String        // e.g. "node", "Python", "docker"
    var arguments: String      // full argv, used to guess a friendly name
    var executablePath: String // resolved from the pid, not from the process's own claims
    var hosts: Set<String>     // every address the process bound to on this port

    /// True when the socket is bound to a wildcard address, i.e. other
    /// machines on the LAN can reach it too.
    var isExposedToLAN: Bool {
        hosts.contains { $0 == "*" || $0 == "0.0.0.0" || $0 == "::" || $0 == "[::]" }
    }

    /// The address to probe and to open. `localhost` is deliberately not used:
    /// it resolves to both ::1 and 127.0.0.1, which can be two different
    /// processes, so the browser could land somewhere we never probed.
    var address: String {
        if hosts.contains(where: { $0 == "*" || $0 == "0.0.0.0" || $0.hasPrefix("127.") }) { return "127.0.0.1" }
        if hosts.contains(where: { $0 == "::" || $0 == "[::]" }) { return "[::1]" }
        if let ipv6 = hosts.first(where: { $0.contains(":") }) {
            return ipv6.hasPrefix("[") ? ipv6 : "[\(ipv6)]"
        }
        return hosts.first ?? "127.0.0.1"
    }

    /// The executable is where macOS keeps its own daemons; a process cannot
    /// move itself there without root.
    var isApplePath: Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/Library/Apple/"]
            .contains { executablePath.hasPrefix($0) }
    }

    /// A readable name for the process. Interpreters (node, python, ...) are
    /// useless on their own, so for those we surface the script being run.
    var derivedName: String {
        let interpreters: Set<String> = ["node", "python", "python3", "ruby", "php", "bun", "deno", "java"]
        let exe = command.lowercased()
        if interpreters.contains(exe) {
            let argv = arguments.split(separator: " ").map(String.init)
            for arg in argv.dropFirst() where !arg.hasPrefix("-") {
                let leaf = (arg as NSString).lastPathComponent
                if !leaf.isEmpty && leaf.lowercased() != exe,
                   let name = DisplayText.sanitize(leaf, limit: 40) { return name }
            }
        }
        return command
    }
}

enum PortScanner {
    static func scan() -> [ListeningPort] {
        let raw = shell("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
        guard !raw.isEmpty else { return [] }

        let argvByPID = processArguments()
        var byKey: [String: ListeningPort] = [:]
        var pid: Int32 = 0
        var command = ""

        for line in raw.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = DisplayText.sanitize(unescape(value), limit: 40) ?? "unknown"
            case "n":
                guard let (host, port) = splitAddress(value) else { continue }
                let key = "\(pid):\(port)"
                if var existing = byKey[key] {
                    existing.hosts.insert(host)
                    byKey[key] = existing
                } else {
                    let argv = argvByPID[pid].flatMap { DisplayText.sanitize($0, limit: 400) } ?? command
                    byKey[key] = ListeningPort(port: port, pid: pid, command: command,
                                               arguments: argv,
                                               executablePath: executablePath(for: pid) ?? "",
                                               hosts: [host])
                }
            default: break
            }
        }
        return Array(byKey.values).sorted { $0.port < $1.port }
    }

    /// The kernel's view of what a pid is actually running, as opposed to the
    /// name the process reports for itself.
    private static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// lsof prints names like "*:8080", "127.0.0.1:5432" or "[::1]:3000".
    private static func splitAddress(_ name: String) -> (host: String, port: Int)? {
        guard let sep = name.lastIndex(of: ":") else { return nil }
        let host = String(name[name.startIndex..<sep])
        let portPart = String(name[name.index(after: sep)...])
        guard let port = Int(portPart), (1...65535).contains(port) else { return nil }
        return (host.isEmpty ? "*" : host, port)
    }

    /// lsof escapes non-printables as \xNN; only spaces show up in practice.
    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\x20", with: " ")
    }

    private static func processArguments() -> [Int32: String] {
        let raw = shell("/bin/ps", ["-axo", "pid=,args="])
        var result: [Int32: String] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sep = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[trimmed.startIndex..<sep]) else { continue }
            result[pid] = trimmed[trimmed.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func shell(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
