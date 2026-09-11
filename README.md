# Quad Monitor

**Quad Monitor is an optimization project based on RacerUSB, improving display transfer performance and usability.** It was developed from analysis of RacerUSB's USB display behavior and protocol.

The app turns three RACERTECH USB DISP panels connected through one USB-C cable into independent extended Mac displays. It prioritizes responsive cursor and window movement during coding and document work.

The current macOS prerelease is **0.3.1, implemented in Swift/C and running without Python**. Windows ARM64 is at the shared-core development stage. See [current status and next steps](docs/current-status.md).

## Installation and launch

Use the [0.3.1 signed installer](https://github.com/kimmingul/quadmonitorDriver/releases/download/v0.3.1/QuadMonitor-0.3.1-arm64.pkg). It targets Apple Silicon/macOS 26 or later and includes the panel ID/location mapping verified in this project. It is Developer ID signed; Apple notarization remains pending.

```bash
open "/Applications/Quad Monitor.app"
```

Apply settings in this order: **Stop → change options → Start**. Grant Screen Recording permission to the installed app. Preferences are stored at `~/Library/Application Support/Quad Monitor/control/preferences.json`; logs are in `runs/` under the same `Quad Monitor/` directory.

## Settings

| Option | Range |
|---|---|
| Language | System (default) / Korean / English / Simplified Chinese; unsupported system languages fall back to English |
| Displays | At least one of right 1 / left 2 / top 3, from the user's perspective |
| CPU encoding workers | 1 / 2 / 4 / 8 / automatic |
| Change detection | CPU / Metal GPU; JPEG encoding runs on the CPU |
| Transfer scheduling | periodic / arrival |
| Compression and updates | delta / full using device-compatible JPEG 4:4:4 |
| Capture buffers | queueDepth 2 / 3 / 5 |
| Additional algorithms | Buffer reuse / adaptive worker count / preparation during transfer |
| Update limit | 2 / 10 / 30 / 60fps, demo mode |

Deselecting a panel does not turn off its power. Enabling every option is not always faster, and USB completion rate differs from physical display rate. User satisfaction with the earlier Python relay version does not establish the still-unverified hardware performance of native 0.3.x.

## Development

```bash
scripts/build_native_app.sh
scripts/build_native_installer.sh
scripts/test_product.sh
```

[macOS development and signing](docs/development.md) · [Essential tests](tests/README.md) · [Windows ARM64](windows/README.md)

```text
App/               macOS source and Swift tests
windows/           Windows shared core and C++ tests
config/            Panel configuration
tests/             Independent validation and minimal fixtures
scripts/           Build, signing, validation, and source packaging
docs/              Product status, development, specifications, and decisions
artifacts/         Performance algorithm guides
releases/          Release paths and hashes
build/             Current app, installer, and Windows source ZIP
```

[Documentation index](docs/README.md) · Algorithm guide: [English](artifacts/quad-monitor-algorithms.html) / [Korean](artifacts/quad-monitor-algorithms.ko.html) / [Simplified Chinese](artifacts/quad-monitor-algorithms.zh-Hans.html) · [Releases](releases/README.md) · [External archive and restoration](docs/archive.md)

Keep source, essential tests, core documentation, and releases in the working directory. Long experiment logs, intermediate builds, and old handoff documents are in the external archive. Git history and development-tool connection settings are retained.

Project documentation is written in English. Artifacts provide English, Korean, and Simplified Chinese editions with the same content and measurement data.
