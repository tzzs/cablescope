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

- No telemetry, no analytics, no crash reporting, no tracking.
- Nothing from your machine is ever uploaded. Any data CableScope creates stays on your Mac.

## The only outbound request

The **Check for Updates** action in the menu bar panel sends one `GET` request to `api.github.com` to fetch the latest release tag of this repository, so it can tell you when a new version is available. It is triggered only when you click that item — there is no automatic or background checking, no identifiers or machine information are sent, and nothing from the response is stored. Everything else works fully offline.

A machine-readable `PrivacyInfo.xcprivacy` (required for App Store submissions) is bundled with the app: no tracking, no collected data types, and a `DiskSpace` required-reason declaration for the optional CLI throughput benchmark (free-space check before writing its test file).

## Deleting your data

Quit CableScope (and stop any running CLI command), then delete the data directory:

```bash
rm -rf "$HOME/Library/Application Support/CableScope"
```

All rating history is removed; the tool recreates an empty directory on next launch.
