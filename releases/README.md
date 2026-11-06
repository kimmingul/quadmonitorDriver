# Release 0.3.2

**Prerelease for Apple Silicon/macOS 26 or later.** The app and installer are Developer ID signed. Apple notarization and native physical-panel acceptance remain pending.

[GitHub release](https://github.com/kimmingul/quadmonitorDriver/releases/tag/v0.3.2) · [Changelog](../CHANGELOG.md) · [Machine-readable manifest](manifest.json)

| Download | Bytes | Purpose |
|---|---:|---|
| [QuadMonitor-0.3.2-arm64.pkg](https://github.com/kimmingul/quadmonitorDriver/releases/download/v0.3.2/QuadMonitor-0.3.2-arm64.pkg) | 816,277 | Developer ID signed macOS installer |
| [QuadMonitor-0.3.2-arm64.app.zip](https://github.com/kimmingul/quadmonitorDriver/releases/download/v0.3.2/QuadMonitor-0.3.2-arm64.app.zip) | 807,930 | Developer ID signed macOS app archive |
| [QuadMonitor-Windows-ARM64-source.zip](https://github.com/kimmingul/quadmonitorDriver/releases/download/v0.3.2/QuadMonitor-Windows-ARM64-source.zip) | 17,934 | Windows shared-core source only |

0.3.2 adds Dock pinning: while a session runs, the bottom Dock stays on the system main display. It needs Accessibility permission, requested at the first Start. The app archive contains `Quad Monitor.app`; the package installs it into `/Applications`. The Windows ZIP contains shared-core source and offline tests only, not a Windows display app or driver. The three algorithm HTML editions are also attached to the GitHub release.

Local outputs are in `build/`, which is Git-ignored. After cloning, download the release assets or follow the [build guide](../docs/development.md). The release tag `v0.3.2`, root `VERSION`, and installer/app short version must agree; bundle build is 5.

The installed app was not replaced during release preparation. Existing preferences at `~/Library/Application Support/Quad Monitor/control/preferences.json` are kept; files without `pinDock` load with Dock pinning on. To roll back, stop the app and reinstall the [0.3.1 package](https://github.com/kimmingul/quadmonitorDriver/releases/tag/v0.3.1).

Validation: Swift product tests including Dock guard geometry and preference compatibility, Developer ID signature checks, and relocated execution of the signed app. Dock pinning was exercised on Quad virtual panels: an unguarded bottom-edge press moved the Dock to a panel, guarded presses (middle and corner) left it on the main display, and a relocated Dock was moved back. No physical USB panel performance, reconnect, sleep, or endurance acceptance was performed; see [current status](../docs/current-status.md).

## SHA-256

The release `SHA256SUMS.txt` covers the three distribution archives and three HTML guides. Archive hashes:

```text
8a719584ac6f3996ba7c10ce0a732d2944a4e36912e5161ea186349a77d9e8aa  QuadMonitor-0.3.2-arm64.pkg
85557e898c10d1ef16c33bc7ce839d7503736827a0201a56cddb2299173158e6  QuadMonitor-0.3.2-arm64.app.zip
8c0b576b126cc662e3e610f170905df44a4d81b622e5994beb384c879bf8987a  QuadMonitor-Windows-ARM64-source.zip
```
