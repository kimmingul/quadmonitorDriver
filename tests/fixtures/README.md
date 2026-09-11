# Minimal regression inputs

`manifest.json` records original paths, SHA-256, and sizes. Original paths are relative to `project/` in the [external archive](../../docs/archive.md) and are not current runtime dependencies.

- `vendor_fixtures.json`: Input hashes, output, and DQT for geometry/ac_pattern/aligned_footer from the vendor machine-code oracle. Reconstruct synthetic inputs with `../support/oracle_patterns.py`.
- `parallel-encoder-fixtures.json`: Lengths and hashes of serial encoder output before parallelization, used for byte-exact parallel comparisons.
- `coldframe_000.bin`: One actual complete vendor frame for full 1920×1200 container validation.
- The manifest also records the preserved panel-configuration hash. Runtime configuration is at `../../config/panel-layout.json`.

The vendor JSON's frame_hex is the encodeFrame return value and excludes the extra USB transport byte. Append one zero byte only in test memory. aligned_footer is 256×16. Preserve positive checks that the independent validator accepts the correct full tile count; do not modify the original JSON.
