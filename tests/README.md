# Product tests

## Automated checks

Run on macOS with Swift/Xcode, CMake, and uv. Python, NumPy, and Pillow are used only by independent validation tools; they are not required by the app or production build.

```bash
scripts/test_product.sh
```

The script builds Swift/CMake caches in a temporary directory and removes them on exit. Set `QUAD_MONITOR_TEST_BUILD_DIR=/desired/path` to retain an external build directory. This command does not produce USB output or create virtual displays.

| Check | Retained scope |
|---|---|
| 47 Swift tests | App configuration, languages, recovery, frame preparation, sessions, and native USB contracts |
| 29 Python tests | Reference codec, independent libjpeg pixels, production C encoder, parallel byte-exact output, and production C validator |
| 4 CTest cases | Shared-core concurrent initialization, vendor frames, encoder, and bounds checks |

Of the previous 78 Python tests, **29 required for the product were retained**. The other 49 covered the old Python coordinator/pipe/recovery, packaging/analysis tools, or the previous standalone C validator and were archived with those implementations. Tests were not removed to hide failures. The six cases inherited by the production C validator continue in `support/validator_cases.py`. Distinguish the historical 129-test pass record from the current 80-test scope.

## Layout

- `fixtures/`: Original vendor cases, serial-output goldens, one complete frame, SHA-256, and provenance.
- `support/`: Independent Python codec/validator, synthetic inputs, and ctypes adapters; not the old app runtime or USB worker.
- `test_*.py`: Comparisons of production encoder/validator behavior against independent oracles.
- `native_sanitizer.c`, `native_validator_sanitize.c`: ASan/UBSan harnesses for production C boundaries.
- macOS Swift tests are in `App/Tests/`; Windows core checks are in `windows/tests/`.

Regenerate tables with `python3 tests/support/generate_native_tables.py`. Changes must pass both golden-output and independent-decoder checks. Do not overwrite original fixtures.

## Actual capture and device checks

```bash
scripts/verify_native_app.sh
scripts/test_native_lifecycle.sh
```

The first command checks the current build app's signature, relocated execution, dependencies, and device enumeration. The second briefly runs real virtual displays and SCK to check lifetime behavior without USB bulk output. End any actual work session and confirm permissions first. Actual USB, reconnect, sleep, endurance, and user-perceived responsiveness require separate acceptance checks.

Store long runtime logs and new experiment originals outside the project. See [current validation limits](../docs/current-status.md) and [historical restoration](../docs/archive.md).
