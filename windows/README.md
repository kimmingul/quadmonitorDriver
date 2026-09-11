# Quad Monitor — Windows11 ARM64 port

This is the first development slice: a shared C codec/validator library, a native ARM64 CMake build, and offline C++ tests. **It is not yet a Windows monitor app or display driver.** No USB interface is opened, no driver is installed, and no system binding is changed by these tests.

The target is a physical Windows11 ARM PC. Python is not required to build or run this slice.

## Build on the Windows PC

Install Visual Studio with C++ ARM64 build tools, a Windows SDK, and CMake. The Windows Driver Kit is needed for the later IddCx stage, not for this codec test. Open PowerShell in the extracted project root:

```powershell
.\windows\build-core.ps1
```

If PowerShell script execution is restricted, run the underlying commands directly; there is no need to change machine policy:

```powershell
cmake -S windows -B build/windows-arm64 -A ARM64
cmake --build build/windows-arm64 --config Release
ctest --test-dir build/windows-arm64 -C Release --output-on-failure
```

CMake uses an installed Visual Studio generator. To select a specific installed version, pass `-Generator 'Visual Studio 17 2022'` to the script, or the corresponding generator with `-G` to CMake. Current Visual Studio versions need a CMake version that recognizes their generator. The test compilation rejects a Windows x64/x86 target, so emulation is not mistaken for an ARM64 build.

Expected: four CTest cases pass (`concurrent_init`, `vendor_frames`, `encoder`, `guards`). Keep the build output and `build/windows-arm64/Testing/Temporary/LastTest.log` for review. Windows compilation and execution remain unverified until these are run on the target PC.

## Shared source and scope

CMake compiles the same files under `App/Sources/CFrameEncoder/` as the macOS app. The public header supports C++ linkage and uses standard `ptrdiff_t`; Windows initialization uses `InitOnceExecuteOnce`, while macOS keeps `pthread_once`. Codec/transport bytes are unchanged. On Windows the existing encoder currently follows the serial fallback even when a higher worker count is passed; Windows parallel scheduling is a later stage and must not be presented as implemented.

The macOS installed app and signed0.3.0 artifacts were not rebuilt or replaced for this port. The source tree contains the new portability changes, so its source hash now intentionally differs from the older signed artifact. macOS regression tests cover these changes.

## Next stages

1. Run the offline ARM64 build and tests on the physical PC.
2. Enumerate the three connected USB devices and inspect their current driver bindings without changing them. Establish ID-based panel mapping; macOS bus paths are not Windows device paths.
3. Implement a bounded WinUSB probe with verified configuration,1second settle, complete-frame validation and exact-byte completion checks. Test one panel before all three. General I/O failures stop the session.
4. Implement an ARM64 C++ IddCx driver: independent1920×1200 monitors, Direct3D surfaces, changed tiles/two successful histories, coordinated shutdown and PnP/power handling. Initially use60Hz.
5. Add a separate control app with Korean/English/Simplified Chinese and existing performance options, then signed installation, reconnect/sleep/endurance and user interaction validation.

The initial transport design is a software-enumerated IddCx display driver plus a dedicated WinUSB transport component. The exact device binding and IPC ownership must be finalized from the real PC's enumeration. A manufacturer display driver and our transport cannot be assumed to own the same USB interface concurrently. Do not change driver bindings automatically based on historical Zadig instructions.

## Local validation

On macOS the codec/C++ integration tests can be run without a Windows SDK:

```sh
cmake -S windows -B build/windows-core-host -DCMAKE_BUILD_TYPE=Release
cmake --build build/windows-core-host
ctest --test-dir build/windows-core-host --output-on-failure
```

This validates shared logic and C/C++ linkage, not the `_WIN32` branch, Windows runtime, signing, USB, or display driver.

References: [Microsoft IddCx](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview), [WDK ARM64](https://learn.microsoft.com/en-us/windows-hardware/drivers/download-the-wdk), [WinUSB](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/windows-desktop-app-for-a-usb-device), [one-time initialization](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-initonceexecuteonce).
