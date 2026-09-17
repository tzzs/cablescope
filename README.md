# CableScope

![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-orange) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey) ![License: MIT](https://img.shields.io/badge/License-MIT-yellow) [![CI](https://github.com/tzzs/cablescope/actions/workflows/ci.yml/badge.svg)](https://github.com/tzzs/cablescope/actions/workflows/ci.yml)

macOS menu bar tool that inspects connected cables (USB-C / Thunderbolt) for **charging speed, data transfer speed, video capabilities**, and a **cable rating**.

> 简体中文版说明请见 [README.zh-CN.md](README.zh-CN.md)。

## How It Works

On most Macs, macOS only sees the *negotiated result* of a cable, never the cable itself. On Apple Silicon, CableScope reads the USB-C port controllers (AppleHPM) directly — including the cable's e-marker chip — and surfaces live negotiation info; where e-marker data is unavailable, it infers a **lower bound** on the cable's spec from **historical negotiation peaks** (e.g. PD negotiating 20V × 5A ⇒ the cable must have a 5A e-marker).

## Features

| Area | Details |
| --- | --- |
| ⚡ Charging | Instantaneous power (W), voltage/current, PD contract (shown separately from instantaneous power), PD tier table with the currently negotiated tier marked, charging bottleneck attribution, battery level, live power chart (App) |
| 🔌 Data | Negotiated USB speed (USB 2.0 / 3.x / USB4 / Thunderbolt), device list |
| 🖥 Video | Display list, resolution/refresh rate, DP link rate; external displays are attributed to the specific cable's card (DisplayPort transport node reports its own port directly, matched to the display by EDID identity) |
| 🎛 Port controller | USB-C port controller direct read on Apple Silicon (AppleHPM / AppleTC): port status, plug orientation, supported transports (CC / USB2 / USB3 / USB4 / DisplayPort); Intel and older Macs degrade to inference-only mode |
| 🧬 E-marker | Direct read of the cable's e-marker chip (SOP' Discover Identity): cable speed class, 3A / 5A current rating, vendor ID + product type |
| 🏷 Rating | Cable capability card derived from historical negotiation peaks, persisted locally (per-port buckets, peaks survive unplugging) |
| 🧵 Multi-cable | Devices aggregated into per-port cable sessions (USB root-port grouping + Thunderbolt receptacles): one card per cable in the main window with a selectable per-cable detail, one line per cable in the menu bar, port-grouped CLI output |
| 🔔 Notifications | Plug/unplug system notifications (UNUserNotificationCenter); silently disabled when running unbundled |
| 🔬 IOKit inspector | Full raw IORegistry properties for any class (USB devices, battery, display connects, Thunderbolt ports, …) — App window + CLI subcommand; snapshots and JSON output carry `rawProperties` for each device |

## Installation

```bash
brew install --cask tzzs/tap/cablescope
```

This installs the notarized `CableScope.app` from the [latest GitHub release](https://github.com/tzzs/cablescope/releases). The cask in [tzzs/homebrew-tap](https://github.com/tzzs/homebrew-tap) is updated automatically on every release.

## Quick Start

For building from source, requires macOS 14+ and a Swift 5.10+ toolchain (Xcode 15+).

```bash
# CLI: human-readable output
swift run CableScopeCLI pretty

# CLI: JSON snapshot / continuous watch / cable rating
swift run CableScopeCLI snapshot --pretty
swift run CableScopeCLI watch
swift run CableScopeCLI rating        # --reset clears history

# CLI: dump ALL raw IORegistry properties of a class (json optional)
swift run CableScopeCLI properties                        # default: IOUSBHostDevice
swift run CableScopeCLI properties AppleSmartBattery
swift run CableScopeCLI properties IODisplayConnect --json

# macOS menu bar app (run the SwiftPM executable directly)
swift run CableScopeApp

# Or bundle it into CableScope.app
./scripts/bundle_app.sh release && open build/CableScope.app
```

## CLI Subcommands

| Subcommand | Description |
| --- | --- |
| `snapshot` (default) | Print a JSON snapshot (`--pretty` for formatted output) |
| `pretty` | Sectioned human-readable output (power / cable ports / displays); devices grouped per physical port with hub-depth indentation |
| `watch` | Watch for changes and print diff lines on content change (`--interval N` adjusts the fallback polling interval) |
| `rating` | Record and show the cable capability card (persisted under `~/Library/Application Support/CableScope/`); `--reset` clears it |
| `properties [Class]` | Enumerate IORegistry entries of an IOKit class and print **all** raw properties (ioreg-style text; `--json` for structured output) |
| `throughput` | Optional read/write throughput benchmark on a mounted USB volume (writes a temporary test file; `--volume <path\|name>` picks the volume, `--seconds N` adjusts per-phase duration, default 5s) |

## Project Layout

```
Sources/
├── CableKit/          # System I/O adapter layer (Swift Package library)
│   ├── Models/        #   Data contracts: CableSnapshot / CableSession / CableRating (Codable + Sendable)
│   ├── Services/      #   USBService / PowerService / DisplayService / ThunderboltService / RegistryService
│   ├── Monitor/       #   CableMonitor: snapshot composition + event stream (AsyncStream)
│   └── Rating/        #   CableRatingEngine: historical peaks → cable rating, bucketed per cable session (pure Swift, unit-testable)
├── CableScopeCLI/     # Command-line tool
└── CableScopeApp/     # SwiftUI menu bar app (MenuBarExtra + main window + Swift Charts power chart)
Tests/
├── CableKitTests/       # 130 tests: data contracts, per-port rating engine + migration, grouping, parsers (real-device samples), diagnostics, vendor directory, rating store + live smoke tests
└── CableScopeCLITests/  # 43 tests: argument parsing (incl. throughput), formatting, watch snapshot diffing
Docs/                  # Data-source guide (IOKit) & optimization roadmap
scripts/bundle_app.sh  # .app bundling script
```

## Data Sources (see [Docs/03-数据获取指南.md](Docs/03-数据获取指南.md) for details)

- **USB**: IOKit `IOUSBHostDevice` (negotiated speed, LocationID, VID/PID)
- **Charging**: IORegistry `AppleSmartBattery` (instantaneous power = `AdapterDetails.AdapterVoltage` × top-level `Amperage`; PD contract = values in `AdapterDetails`) + `ioreg`-based battery info via IOKit.ps
- **Displays**: CoreGraphics (resolution/refresh rate) + `NSScreen.localizedName` (macOS 26 removed CGDisplayProductName)
- **Thunderbolt**: `system_profiler SPThunderboltDataType -json`, recursively flattened

## Status

- [x] CableKit adapter layer (USB/power/displays/Thunderbolt + snapshot stream + rating engine) — 189/189 tests passing (including the CLI test target)
- [x] All six CLI subcommands (validated on real hardware: PD contract detection, e-marker inference, rating persistence)
- [x] macOS menu bar app (system overview, one card per cable with per-cable detail, live power chart, per-port rating)
- [x] IOKit property inspector (App window + CLI `properties` subcommand; snapshots carry full `rawProperties`)
- [x] Multi-cable layout (per-port cable sessions, USB root-port grouping + Thunderbolt receptacle numbers, legacy ratings.json migration)
- [x] Plug/unplug system notifications (UNUserNotificationCenter)
- [x] Real-world USB throughput measurement (CLI `throughput` subcommand + App "Throughput" section: read/write benchmark on a mounted volume)
- [x] IOKit notifications to replace polling (AppleSmartBattery interest + USB matching notifications with polling fallback)
- [x] App icon (classic Assets.car appiconset + Icon Composer Liquid Glass layers, both Xcode and SwiftPM/DMG paths)
- [ ] Official distribution (notarized DMG release; tag `v0.1.0` cut locally, GitHub Secrets and the actual signed release still pending)

### Known Limitations

- E-marker direct read requires Apple Silicon (AppleHPM); on Intel/older Macs — and for cables without an e-marker — the rating is a "lower-bound inference from negotiation peaks", labeled as such in both the UI and the CLI. Branded specs still cannot be read.
- Charging power **cannot be attributed to a specific cable** in the multi-cable case (macOS only exposes the active adapter, so with several cables plugged in there's no way to tell which one is receiving power unless exactly one port has a negotiated contract): it stays in the system overview then. With exactly one cable connected, charging status is promoted onto that cable's card.
- External displays **are** attributed to a specific cable: an `IOPortTransportStateDisplayPort` transport node reports its own owning USB-C/MagSafe port directly (`DisplayPortTransportService` + `PortGrouping.displayPortLinks`), and is matched to its `CGDirectDisplayID` by EDID identity (`PortGrouping.matchedDisplay`) to pull in resolution/refresh rate. When that EDID match isn't unique (e.g. a dock driving two identical monitors), only the link's own vendor/model info is shown — no guessed resolution.
- Physical port labels are technical ("USB 端口 0x014" / "雷雳端口 2"); friendly left/right positions would require registry port-topology work (v2).
- The built-in display has no DP link rate field, and `DisplaySnapshot.linkRateLabel` (parsed best-effort from `system_profiler`) only becomes meaningful when an external DP/Thunderbolt display is connected. The per-cable card's DisplayPort link rate (`DisplayPortLinkSnapshot.linkRateDescription`) comes from the dedicated transport node instead and is reliably populated whenever the link exists.
- `watch`/the snapshot stream use event-driven wake-ups (AppleSmartBattery interest + USB matching notifications) with fallback polling for content-change detection.
- The `.app` bundling script is intended for local use; App Store/notarized distribution should later move to an Xcode project.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup (`swift build` / `swift test`), a one-minute tour of the code structure, PR guidelines (including the `usb-vendors.json` vendor-entry format and the fixture-test requirement), and the project's wording rules.

When filing an issue, please include your Mac model and chip, macOS version, and the IORegistry output of the relevant classes (e.g. `swift run CableScopeCLI properties <Class> --json`).

## License

[MIT](LICENSE) — free to use, modify, and redistribute. CableScope collects and stores all data locally on your machine (no telemetry, no network requests) — see [PRIVACY.md](PRIVACY.md).
