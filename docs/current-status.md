# Current status and next steps — 2026-09-12

## macOS

The current prerelease is **Quad Monitor 0.3.1**, a Swift/C app for Apple Silicon/macOS 26 or later. Python runtime and production-build dependencies have been removed. It supports three independent displays, Korean/English/Simplified Chinese, panel selection, and CPU/Metal, scheduling, buffering, adaptive worker, and speculative preparation options.

Developer ID Application/Installer signing, installation, relocated execution, and preference preservation were verified. Apple notarization remains pending. Current source includes Windows portability and path changes made after release; do not assume its hashes match the installed app. The repository reorganization did not replace the installed app or existing macOS 0.3.0 package.

During the native transition, normal exit, Stop, and failure cleanup were verified for three virtual displays. No USB devices were connected then, so **native hardware transfer, perceived responsiveness, reconnect, sleep, and endurance validation remain pending.** The earlier Python relay version achieved user satisfaction, actual recovery, and a successful 2-hour test; those results do not validate the new version on hardware.

The cursor result of 52.40→60.00 USB completions/s and the five-option comparison with 13,481 frames and zero errors came from the earlier Python path. Speculative preparation did not demonstrate an output improvement. Physical fps and input-to-panel latency require separate measurement. See the [algorithm guide](../artifacts/quad-monitor-algorithms.html).

## Windows ARM64

A shared C core and four C++/CMake/CTest cases are prepared for a physical Windows ARM PC. They were tested on a Mac host; Windows ARM64 compilation/execution and the `_WIN32` branch remain unverified. WinUSB, IddCx, the control UI, and signed installation are incomplete. The source ZIP is not an installable app. See the [Windows guide](../windows/README.md).

## Next steps

1. Inspect the installed macOS version, signature, current preferences, and USB IDs/paths. Do not treat historical PIDs or settings as current observations.
2. With the same build, run a short three-panel LIVE check, verify the first two full frames, exact completion, and normal cleanup, and ask the user to confirm panel roles and motion.
3. Validate ordinary work, one-variable comparisons where needed, one/two selected panels, reconnect, sleep, partial panel absence, and 2-hour stability against the final hashes. Avoid unnecessary rebuilds, TCC resets, and repeated historical experiments.
4. Obtain the project location and access method on the Windows PC, then start with ARM64 core tests.
5. After hardware acceptance, proceed with macOS notarization and distribution. 120fps, hardware cursors, and new codecs are candidates requiring separate evidence.

See the [test guide](../tests/README.md) for automated checks, [releases](../releases/README.md) for hashes, and the [external archive](archive.md) for historical originals. Product source still contains uncommitted implementation; Git HEAD alone does not identify the executing code.

## Product repository reorganization validation

Verified 47 Swift tests, 29 production C/independent-oracle tests, four CMake tests, two ASan/UBSan harnesses, an external temporary Developer ID installer build and relocated execution, and a host build of the extracted Windows source ZIP. App algorithms, the installed app, and the existing macOS package were preserved. See the [validation summary](validation.json). Long logs and removed intermediate materials are in the [external archive](archive.md).

The source directory is now `App/`, and the Swift package/app module is `QuadMonitor`. The README explicitly identifies the project as an optimization based on RacerUSB. After renaming, all 80 tests, Developer ID app/installer builds, relocated execution, three packaged languages with English fallback, and extracted Windows ZIP core checks passed again. Validation builds are stored externally; existing macOS releases and the installed app were retained.

## 0.3.1 release validation — 2026-09-12

Rebuilt the current source as 0.3.1 (bundle build 4), signed the app and helpers with Developer ID Application and the installer with Developer ID Installer, and verified signatures and relocated execution. The 80 product tests, two ASan/UBSan harnesses, and real virtual-display/SCK lifecycle scenarios (bounded run, manual Stop, and worker failure cleanup) passed. No USB device was connected during these checks; physical panel performance, reconnect, sleep, and endurance remain pending. Apple notarization remains pending. Accordingly, 0.3.1 is a prerelease.

The signed outputs in `build/` are updated; `/Applications/Quad Monitor.app` was not replaced. The original local development history is retained locally and in external backups. The new public repository starts from the current product source without historical packet captures, extracted vendor executables, or machine-specific MCP settings. See the [release record](../releases/README.md).
