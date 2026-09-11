# Vendor fixture provenance

The `.hex` files are byte-for-byte hex fields from `tests/fixtures/vendor_fixtures.json (the original historical path is preserved in the external project archive)` (original vendor machine-code oracle). `geometry` and `ac_pattern` are64×16; `aligned_footer` is256×16. `dqt.hex` contains the original138-byte configuration tables.

The archived `encodeFrame` results are128-byte aligned and exclude the extra USB transport byte. Tests preserve these originals, append the production encoder's deterministic zero in memory, then validate. The raw encoder results must be rejected as complete USB frames. Vendor per-tile alignment padding is not deterministic; encoder comparison checks entropy through EOI, not those padding bytes.

These small deterministic images contain no captured user desktop content. The original decoder/independent libjpeg checks remain in `tests/` and are not needed to run CTest on Windows.
