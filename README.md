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
| 🖥 Video | Display list, resolution/refresh rate, DP link rate (with an external display) |
| 🎛 Port controller | USB-C port controller direct read on Apple Silicon (AppleHPM / AppleTC): port status, plug orientation, supported transports (CC / USB2 / USB3 / USB4 / DisplayPort); Intel and older Macs degrade to inference-only mode |
| 🧬 E-marker | Direct read of the cable's e-marker chip (SOP' Discover Identity): cable speed class, 3A / 5A current rating, vendor ID + product type |
| 🏷 Rating | Cable capability card derived from historical negotiation peaks, persisted locally (per-port buckets, peaks survive unplugging) |
| 🧵 Multi-cable | Devices aggregated into per-port cable sessions (USB root-port grouping + Thunderbolt receptacles): one card per cable in the main window with a selectable per-cable detail, one line per cable in the menu bar, port-grouped CLI output |
| 🔔 Notifications | Plug/unplug system notifications (UNUserNotificationCenter); silently disabled when running unbundled |
| 🔬 IOKit inspector | Full raw IORegistry properties for any class (USB devices, battery, display connects, Thunderbolt ports, …) — App window + CLI subcommand; snapshots and JSON output carry `rawProperties` for each device |

## Quick Start

Requires macOS 14+ and a Swift 5.10+ toolchain (Xcode 15+).

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
├── CableKitTests/       # 70 tests: data contracts, per-port rating engine + migration, grouping, four parsers (real-device samples) + live smoke tests
└── CableScopeCLITests/  # 34 tests: argument parsing, formatting, watch snapshot diffing
Docs/                  # Data-source guide (IOKit) & optimization roadmap
scripts/bundle_app.sh  # .app bundling script
```

## Data Sources (see [Docs/03-数据获取指南.md](Docs/03-数据获取指南.md) for details)

- **USB**: IOKit `IOUSBHostDevice` (negotiated speed, LocationID, VID/PID)
- **Charging**: IORegistry `AppleSmartBattery` (instantaneous power = `AdapterDetails.AdapterVoltage` × top-level `Amperage`; PD contract = values in `AdapterDetails`) + `ioreg`-based battery info via IOKit.ps
- **Displays**: CoreGraphics (resolution/refresh rate) + `NSScreen.localizedName` (macOS 26 removed CGDisplayProductName)
- **Thunderbolt**: `system_profiler SPThunderboltDataType -json`, recursively flattened

## Status

- [x] CableKit adapter layer (USB/power/displays/Thunderbolt + snapshot stream + rating engine) — 164/164 tests passing (including the CLI test target)
- [x] All five CLI subcommands (validated on real hardware: PD contract detection, e-marker inference, rating persistence)
- [x] macOS menu bar app (system overview, one card per cable with per-cable detail, live power chart, per-port rating)
- [x] IOKit property inspector (App window + CLI `properties` subcommand; snapshots carry full `rawProperties`)
- [x] Multi-cable layout (per-port cable sessions, USB root-port grouping + Thunderbolt receptacle numbers, legacy ratings.json migration)
- [x] Plug/unplug system notifications (UNUserNotificationCenter)
- [ ] Real-world USB throughput measurement (5-second read/write benchmark)
- [ ] IOKit notifications to replace polling, official distribution (notarization), app icon

### Known Limitations

- E-marker direct read requires Apple Silicon (AppleHPM); on Intel/older Macs — and for cables without an e-marker — the rating is a "lower-bound inference from negotiation peaks", labeled as such in both the UI and the CLI. Branded specs still cannot be read.
- Displays and charging power **cannot be attributed to a specific cable** (macOS only exposes the active adapter and has no display→port mapping): they stay in the system overview. With exactly one cable connected, charging status is promoted onto that cable's card.
- Physical port labels are technical ("USB 端口 0x014" / "雷雳端口 2"); friendly left/right positions would require registry port-topology work (v2).
- The built-in display has no DP link rate field; `linkRateLabel` only becomes meaningful when an external DP/Thunderbolt display is connected.
- `watch`/the snapshot stream currently use content-change detection with fallback polling (IOKit notification bridging is on the roadmap).
- The `.app` bundling script is intended for local use; App Store/notarized distribution should later move to an Xcode project.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup (`swift build` / `swift test`), a one-minute tour of the code structure, PR guidelines (including the `usb-vendors.json` vendor-entry format and the fixture-test requirement), and the project's wording rules.

When filing an issue, please include your Mac model and chip, macOS version, and the IORegistry output of the relevant classes (e.g. `swift run CableScopeCLI properties <Class> --json`).

## License

[MIT](LICENSE) — free to use, modify, and redistribute. CableScope collects and stores all data locally on your machine (no telemetry, no network requests) — see [PRIVACY.md](PRIVACY.md).
