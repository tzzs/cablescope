# Contributing to CableScope

Thanks for considering a contribution! This document covers local setup, a one-minute tour of the codebase, PR guidelines, and the project's wording rules.

## Local development

Requires macOS 14+ and a Swift 5.10+ toolchain (Xcode 15+).

```bash
swift build                            # build everything (CableKit, CLI, App)
swift test                             # run all test targets
swift run CableScopeCLI pretty         # human-readable snapshot of the current state
swift run CableScopeCLI snapshot --pretty
swift run CableScopeApp                # menu bar app (unbundled)
```

Two kinds of tests live in `Tests/`:

- **Fixture tests** parse captured real-device IORegistry samples. They are deterministic and must pass on any machine, regardless of what is plugged in.
- **Smoke tests** (`RealEnvironmentSmokeTests`) call the real services and never assume any specific hardware exists — they must pass on an empty machine too.

## The codebase in one minute

```
Sources/CableKit/     # System I/O adapter layer — THE ONLY LAYER THAT TOUCHES IOKIT
├── Models/           #   Value-type data contracts (Codable + Sendable snapshots)
├── Services/         #   IOKit / system_profiler wrappers (USB, power, displays,
│                     #   Thunderbolt, USB-C port controllers, registry inspector)
├── Monitor/          #   CableMonitor: snapshot composition + AsyncStream
├── Rating/           #   Pure rating engine + RatingStore (persistence)
└── Diagnostics/      #   Pure diagnostics functions (bottleneck attribution, headlines)
Sources/CableScopeCLI/  # CLI — consumes CableKit value types only
Sources/CableScopeApp/  # SwiftUI menu bar app — consumes CableKit value types only
```

The layering rule is simple: **all system access lives in CableKit**. The CLI and the App only consume value types. New system reads belong in a CableKit service, with the parsing isolated in a pure function that can be unit-tested against captured samples.

## Pull requests

- Keep the layering: no IOKit / CoreGraphics / `system_profiler` calls in `CableScopeCLI` or `CableScopeApp`.
- **New parsing logic must ship with fixture tests built from real-device samples.** See the existing parser tests under `Tests/CableKitTests/` (e.g. `PortParsingTests`, `PowerParsingTests`) for the pattern: capture the real IORegistry properties, embed them as fixtures, assert the parsed result. If you could not capture a real sample, say so in the PR description.
- **Keep both READMEs in sync**: user-facing changes to `README.md` must be mirrored in `README.zh-CN.md` (same information, Chinese wording), and vice versa. Update `Docs/` when behavior or data sources change.
- Run `swift test` before pushing; all tests must pass.

### Vendor database entries (`usb-vendors.json`)

The VID → vendor-name database is community-maintained. When adding vendors:

- **One JSON record per real, assigned VID.** Never add placeholder or "just in case" entries.
- **Note your source** for every record — e.g. the USB-IF vendor ID list or the `usb.ids` file. Records look like:

  ```json
  { "vid": "0x0424", "vendor": "Microchip Technology Inc. (formerly SMSC)", "source": "usb.ids" }
  ```

- Do not invent, guess, or "improve" vendor names; use the name exactly as your source spells it.

### Wording red lines

These exist so the tool never claims to know more than it does:

- **Never output a "fake cable" verdict.** If e-marker data looks unusual (zero VID, reserved bit values, an unlisted VID), describe what was read ("VID not reported", "unusual value") — do not label a cable fake, counterfeit, or non-compliant.
- **Capability claims use lower-bound phrasing.** Anything not read directly from the hardware must be phrased as "supports at least …" / "may …". Inferred ratings are inferences from negotiation peaks, never certificates.

## Reporting issues

Please include:

1. Mac model and chip (Apple Silicon or Intel), and the exact macOS version.
2. What is connected (cables, chargers, docks, displays).
3. IORegistry output of the relevant classes, for example:

   ```bash
   swift run CableScopeCLI properties IOUSBHostDevice --json
   swift run CableScopeCLI properties AppleSmartBattery
   swift run CableScopeCLI properties IOThunderboltPort --json
   ```

   (or the matching `ioreg` output). Feel free to redact serial numbers and device names — we don't need them.

---

## 简短中文说明

欢迎参与贡献！要点：

- **本地跑**：`swift build` / `swift test`；试玩数据用 `swift run CableScopeCLI pretty`。冒烟测试不假设任何外设存在，空机器也能跑通。
- **分层红线**：只有 `CableKit` 允许碰 IOKit / 系统接口；CLI 与 App 只消费值类型。
- **PR 要求**：新增解析逻辑必须带真机 fixture 测试；`usb-vendors.json` 一条 JSON 记录一个真实 VID 并注明来源；`README.md` 与 `README.zh-CN.md` 必须同步修改。
- **措辞红线**：不给"假线"判决；凡非直读的能力结论一律用"至少支持 / 可能"表述。
- **报 bug**：请附机型与芯片、macOS 版本，以及相关 IOKit 类的输出（`swift run CableScopeCLI properties <类名> --json`）。
