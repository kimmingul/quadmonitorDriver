# Changelog

## 0.3.2 — 2026-11-06 (prerelease)

### Added

- Dock pinning (default on): while a session runs, the bottom Dock stays on the system main display instead of following the cursor to Quad panels or other displays. Requires Accessibility permission; bottom hot corners on non-main displays may not respond while active.

### Changed

- Build and test scripts use SwiftPM's native build system (Swift 6.4 defaults to Swift Build, whose resource layout the bundle step does not expect), hash sources with `git ls-files` instead of `rg`, and add installer component keys that newer `pkgbuild` omits.

## 0.3.1 — 2026-09-12 (prerelease)

### Added

- First public source release of the native Swift/C macOS app, with a Developer ID signed installer and app archive.
- Independent extended displays, Korean/English/Simplified Chinese UI, panel selection, and CPU/Metal, timing, buffer reuse, adaptive worker, and preparation options carried forward from local development.
- Shared C codec/validator sources and offline tests for the Windows ARM64 port; this is not yet a Windows display driver or installable app.
- English project documentation and standalone English, Korean, and Simplified Chinese interactive algorithm guides.

### Changed

- Consolidated macOS source under `App/` with package/module name `QuadMonitor`, while retaining the displayed name `Quad Monitor` and bundle ID `com.quadmonitor.desktop`.
- Production builds read the release version from `VERSION`; app and installer remain independent of Python.
- Published only the maintained product tree. Original local history and intermediate research remain in external archives and local archive branches.

### Validation and limits

- 47 Swift, 29 independent-oracle Python, and 4 CMake tests passed; two production C ASan/UBSan harnesses passed.
- Developer ID signatures, relocated execution, and bounded/manual-stop/worker-failure virtual-display lifecycle checks passed.
- Algorithm guides preserve historical measurements and pass three-language interaction, responsive-layout, and link checks.
- Apple notarization, native physical USB/panel responsiveness, reconnect, sleep, and endurance validation remain pending. No 120Hz or hardware-cursor support is claimed. Earlier Python-path benchmarks do not measure this native release.

## 0.3.0 — local release

Introduced the Python-free Swift/C session and frame-transfer path. Its signed local artifacts are retained in the external archive. Hardware performance of the native path was not established by the earlier Python relay tests.
