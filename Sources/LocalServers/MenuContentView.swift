import SwiftUI
import AppKit
import ServiceManagement

struct MenuContentView: View {
    @ObservedObject var store: ServerStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let refreshTicker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340)
        .task { await store.refresh() }
        .onReceive(refreshTicker) { _ in Task { await store.refresh() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Local Servers").font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            } else {
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh now")
            }
            optionsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show all ports", isOn: $store.showAllPorts)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
            Divider()
            Button("Quit Local Servers") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .foregroundStyle(.secondary)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        let web = store.webServers
        let others = store.otherPorts

        if web.isEmpty && (!store.showAllPorts || others.isEmpty) {
            VStack(spacing: 4) {
                Image(systemName: "moon.zzz").font(.system(size: 18)).foregroundStyle(.tertiary)
                Text("No local servers running").font(.system(size: 12)).foregroundStyle(.secondary)
                if !store.showAllPorts && !others.isEmpty {
                    Text("\(others.count) other ports hidden")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(web) { entry in ServerRow(entry: entry) }

                    if store.showAllPorts && !others.isEmpty {
                        Text("OTHER LISTENING PORTS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, web.isEmpty ? 6 : 12)
                            .padding(.bottom, 3)
                        ForEach(others) { entry in ServerRow(entry: entry) }
                    }
                }
                .padding(.vertical, 5)
            }
            .frame(maxHeight: 400)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 5) {
            if let ip = store.lanAddress {
                Image(systemName: "wifi").font(.system(size: 9))
                Text(ip).font(.system(size: 10, design: .monospaced))
            } else {
                Text("Offline").font(.system(size: 10))
            }
            Spacer()
            Text("\(store.webServers.count) web · \(store.otherPorts.count) other")
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Row

struct ServerRow: View {
    let entry: ServerEntry
    @State private var hovering = false

    var body: some View {
        Button(action: { open(entry.localURL) }) {
            HStack(spacing: 9) {
                Circle().fill(statusColor).frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if entry.port.isExposedToLAN {
                    Text("LAN")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.secondary)
                }
                if entry.isWeb {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? Color.accentColor : .clear)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open \(entry.localURL.absoluteString)") { open(entry.localURL) }
            if let lan = entry.lanURL {
                Button("Open \(lan.absoluteString)") { open(lan) }
            }
            Divider()
            Button("Copy URL") { copy(entry.localURL.absoluteString) }
            if let lan = entry.lanURL {
                Button("Copy LAN URL") { copy(lan.absoluteString) }
            }
            Button("Copy PID (\(entry.port.pid))") { copy(String(entry.port.pid)) }
        }
    }

    private var subtitle: String {
        var parts = ["localhost:\(entry.port.port)", entry.port.command]
        if let code = entry.probe?.statusCode, code >= 400 { parts.append("HTTP \(code)") }
        else if !entry.isWeb { parts.append("not HTTP") }
        return parts.joined(separator: "  ·  ")
    }

    private var statusColor: Color {
        guard let probe = entry.probe else { return .secondary.opacity(0.5) }
        switch probe.statusCode {
        case 200..<400: return .green
        case 400..<500: return .yellow
        default: return .orange
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        closeMenuBarPanel()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// MenuBarExtra's window style has no dismiss API, so ask the popover to close itself.
func closeMenuBarPanel() {
    NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)
}
