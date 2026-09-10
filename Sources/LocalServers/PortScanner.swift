import Foundation

/// A TCP port that some process on this machine is listening on.
struct ListeningPort: Hashable {
    var port: Int
    var pid: Int32
    var command: String        // e.g. "node", "Python", "docker"
    var arguments: String      // full argv, used to guess a friendly name
    var hosts: Set<String>     // every address the process bound to on this port

    /// True when the socket is bound to a wildcard address, i.e. other
    /// machines on the LAN can reach it too.
    var isExposedToLAN: Bool {
        hosts.contains { $0 == "*" || $0 == "0.0.0.0" || $0 == "::" || $0 == "[::]" }
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
                if !leaf.isEmpty && leaf.lowercased() != exe { return leaf }
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
            case "c": command = unescape(value)
            case "n":
                guard let (host, port) = splitAddress(value) else { continue }
                let key = "\(pid):\(port)"
                if var existing = byKey[key] {
                    existing.hosts.insert(host)
                    byKey[key] = existing
                } else {
                    byKey[key] = ListeningPort(port: port, pid: pid, command: command,
                                               arguments: argvByPID[pid] ?? command,
                                               hosts: [host])
                }
            default: break
            }
        }
        return Array(byKey.values).sorted { $0.port < $1.port }
    }

    /// lsof prints names like "*:8080", "127.0.0.1:5432" or "[::1]:3000".
    private static func splitAddress(_ name: String) -> (host: String, port: Int)? {
        guard let sep = name.lastIndex(of: ":") else { return nil }
        let host = String(name[name.startIndex..<sep])
        let portPart = String(name[name.index(after: sep)...])
        guard let port = Int(portPart) else { return nil }
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
