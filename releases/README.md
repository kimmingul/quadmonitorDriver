# Release 0.3.1

**Prerelease for Apple Silicon/macOS 26 or later.** The app and installer are Developer ID signed. Apple notarization and native physical-panel acceptance remain pending.

[GitHub release](https://github.com/kimmingul/quadmonitorDriver/releases/tag/v0.3.1) · [Changelog](../CHANGELOG.md) · [Machine-readable manifest](manifest.json)

| Download | Bytes | Purpose |
|---|---:|---|
| [QuadMonitor-0.3.1-arm64.pkg](https://github.com/kimmingul/quadmonitorDriver/releases/download/v0.3.1/QuadMonitor-0.3.1-arm64.pkg) | 809,767 | Developer ID signed macOS installer |
| [QuadMonitor-0.3.1-arm64.app.zip](https://github.com/kimmingul/quadmonitorDriver/releases/download/v0.3.1/QuadMonitor-0.3.1-arm64.app.zip) | 805,823 | Developer ID signed macOS app archive |
| [QuadMonitor-Windows-ARM64-source.zip](https://github.com/kimmingul/quadmonitorDriver/releases/download/v0.3.1/QuadMonitor-Windows-ARM64-source.zip) | 17,934 | Windows shared-core source only |

The app archive contains `Quad Monitor.app`; the package installs it into `/Applications`. The Windows ZIP contains shared-core source and offline tests only, not a Windows display app or driver. The three algorithm HTML editions are also attached to the GitHub release.

Local outputs are in `build/`, which is Git-ignored. After cloning, download the release assets or follow the [build guide](../docs/development.md). The release tag `v0.3.1`, root `VERSION`, and installer/app short version must agree.

The installed app was not replaced during release preparation. The previous 0.3.0 app/package and original local history remain in the [external archive](../docs/archive.md). Existing language/performance preferences remain at `~/Library/Application Support/Quad Monitor/control/preferences.json`. To roll back locally, stop the new app and reinstall the retained 0.3.0 package; preserve that preferences directory.

Validation: 80 product tests, two ASan/UBSan harnesses, signed build and relocated execution, and real virtual-display/SCK bounded-run, manual-stop, and worker-failure cleanup checks. No physical USB devices were connected. Windows ARM64 execution, native physical USB, reconnect, sleep, and endurance still require acceptance; see [current status](../docs/current-status.md).

## SHA-256

The release `SHA256SUMS.txt` covers the three distribution archives and three HTML guides. Archive hashes:

```text
a7a08fdedfa4562e582c5900ebc046fba4d7bb62605d2035a768645697bc6df9  QuadMonitor-0.3.1-arm64.pkg
daa2687ba1c34e5dcebceb4c8b8fdb6801a1a2462a5fde00bd57b124fd886b70  QuadMonitor-0.3.1-arm64.app.zip
459db3a694906536109653979de120837f615ddc2dcbcd0369d3d83c5d273bfc  QuadMonitor-Windows-ARM64-source.zip
```
