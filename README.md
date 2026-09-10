# Local Servers

A tiny macOS menu bar app that shows every server running on this machine.
Click the icon in the status bar and you get a dropdown of the local ports that
answer HTTP, with the page title, the port, the process behind it, and whether
it is reachable from the LAN. Clicking a row opens it in your browser.

## What it shows

- **Web servers** — ports that answer with a real page (HTTP 2xx/3xx), pages
  first, then APIs. Named after the served `<title>`, falling back to the
  process (a `node`/`python` process is named after the script it runs).
- **LAN badge** — the socket is bound to `0.0.0.0`/`*`, so other machines on
  the network can reach it. The footer shows this Mac's LAN address.
- **Other listening ports** — endpoints that reject the request (403/404) plus
  non-HTTP listeners and macOS system services. Hidden until you enable
  *Show all ports*.

Right-click a row for the LAN URL, or to copy the URL or PID.
The list refreshes when you open the dropdown and every 5 seconds while it is open.

## Install

```sh
brew install mondial7/tap/local-servers
```

Or build it from source, which puts `Local Servers.app` in `/Applications` and
starts it:

```sh
./install.sh
```

Either way you get a universal binary (arm64 + x86_64). There is no dock icon —
it lives in the menu bar only. Enable *Launch at login* from the `…` menu in the
dropdown to have it always there.

To remove it: `brew uninstall local-servers`, or quit from the dropdown and
`rm -rf "/Applications/Local Servers.app"` for a source install.

The app is ad-hoc signed rather than notarised, so a manual download from the
releases page needs a right-click → Open the first time. The cask strips the
quarantine attribute for you.

## How it works

No dependencies, no elevated privileges, ~600 lines of Swift/SwiftUI:

| File | Role |
| --- | --- |
| `PortScanner.swift` | `lsof -iTCP -sTCP:LISTEN` + `ps` → listening ports with process and argv |
| `Prober.swift` | Concurrent HTTP (then HTTPS) request per port, 1.5s timeout, `<title>` extraction |
| `NetworkInfo.swift` | LAN IPv4 address via `getifaddrs` |
| `ServerStore.swift` | Scan/probe pipeline, ranking, filtering |
| `MenuContentView.swift` | The dropdown |
| `LocalServersApp.swift` | `MenuBarExtra` entry point |

`lsof` runs unprivileged, so the list covers processes owned by you — which is
every dev server you start. Requires macOS 13+.

## Build only

```sh
./build.sh   # → build/Local Servers.app
```
