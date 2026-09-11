# Development and build guide

The macOS product is a native Swift/C app. Development requires Swift/Xcode, build-time libusb, rg, and Developer ID certificates. Python is not required to run the product or produce a production build. The target is Apple Silicon/macOS 26 or later.

## Build and sign

Run from the project root:

```bash
scripts/build_native_app.sh
scripts/build_native_installer.sh
scripts/verify_native_app.sh
```

The app is `build/Quad Monitor.app`; the installer is `build/QuadMonitor-0.3.1-arm64.pkg`. Installer builds also create `build/standalone/Quad Monitor.app`. Replaced build apps are backed up under `build/archive/`. Building alone does not replace the app installed in `/Applications`.

If multiple certificates are available, select the app identity with `--sign-identity` / `QUAD_MONITOR_SIGN_IDENTITY` and the installer identity with `--installer-identity` / `QUAD_MONITOR_INSTALLER_IDENTITY`. Both must belong to the same team. `--sign-identity -` is temporary development signing and cannot be used for a signed installer package. Do not use `--skip-build` after source changes or without an existing build cache. Developer ID signing and Apple notarization are separate.

The release version is read from the root `VERSION` file. The published tag must be `v` followed by that exact version; the installer reads the same version from the signed app. Bundle build 4 identifies 0.3.1.

Configuration input is `config/panel-layout.json`. The bundled `build-sources.sha256` records product source hashes. Do not assume current source hashes match the distributed app.

## Modules

The source directory is `App/`; the Swift package and app executable module are `QuadMonitor`. The displayed app name is `Quad Monitor.app`, and the bundle ID is `com.quadmonitor.desktop`. The [README](../README.md) explains the project's origin as an optimization based on RacerUSB.

| Path under `App/Sources/` | Responsibility |
|---|---|
| `QuadMonitor/App/Desktop*.swift` | AppKit UI, languages/options, Start/Stop, and recovery intent |
| `VerifiedSession/` | Device roles, processes, state, and coordinated cleanup |
| `VerifiedDesktopHost/` | Virtual display layout and lifetime |
| `VerifiedCapture/` | SCK capture, encoding, and direct transfer |
| `VerifiedUSB/` | libusb, ID matching, complete-frame validation, and completion checks |
| `VerifiedDisplayCore/` | Two histories, change detection, CPU/Metal, timing, and preparation |
| `CFrameEncoder/` | JPEG tile encoding and container/entropy validation |

Existing Swift diagnostic branches and legacy pipe APIs remain referenced by the package. The directory cleanup did not reimplement product algorithms or bulk-delete unused Swift symbols.

## Tests and maintenance

Use `scripts/test_product.sh` as described in the [test guide](../tests/README.md). Build caches are created and removed in temporary locations by default. Development and installed apps share language/performance settings at `~/Library/Application Support/Quad Monitor/control/preferences.json`, so do not run them simultaneously.

Follow [windows/README.md](../windows/README.md) for the Windows core. To package current source, run `scripts/package_windows_source.sh` and update the [release manifest](../releases/manifest.json).

Store long build and experiment logs outside the working directory. Update product documents with conclusions, versions, and validation limits. Record important protocol decisions in the [decision record](decisions.md).
