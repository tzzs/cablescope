# Privacy

CableScope is a local-only tool. All data it collects is gathered on your Mac and stored on your Mac.

## What CableScope reads

CableScope queries local system interfaces only:

- IORegistry entries for USB devices, the battery/charger, displays, Thunderbolt ports, and USB-C port controllers (AppleHPM / AppleTC).
- `system_profiler` Thunderbolt data (local command, no network).
- CoreGraphics / `NSScreen` display information.

This can include device names, vendor/product IDs (VID/PID), negotiated speeds, PD contract values, e-marker chip identity, and battery readings.

## Where data is stored

- `~/Library/Application Support/CableScope/` — e.g. `ratings.json`, the per-cable capability history ("negotiation peaks"). Legacy files from older builds (`app-ratings.json`, old `ratings.json`) are migrated into this single file and then removed.
- Nothing else is written outside this directory.

## What never happens

- No telemetry, no analytics, no crash reporting.
- No network requests of any kind. Everything works fully offline.

## The one planned outbound request

A future update-check feature will be the only outbound request CableScope ever makes: fetching **release metadata from GitHub Releases** to tell you when a new version is available. It will never upload any information from your machine.

## Deleting your data

Quit CableScope (and stop any running CLI command), then delete the data directory:

```bash
rm -rf "$HOME/Library/Application Support/CableScope"
```

All rating history is removed; the tool recreates an empty directory on next launch.
