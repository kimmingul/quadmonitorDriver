# Retained design decisions and lessons from failures

## Follow the verified device frame contract

Preserve 32×8 tiles, JPEG 4:4:4, natural-order DQT, the exact footer, and the extra transport byte. Historical mistakes included assuming 16×16/4:2:0, adding no footer when already aligned, and confusing encoder length with USB transfer length. See the [specification](frame_format.md).

## Encoder/decoder agreement alone is insufficient

Cross-check original vendor fixtures, input-pixel SHA-256, independent Pillow/libjpeg decoding, Python entropy checks, and the C validator. A former gap allowed parity checks to pass when both validators rejected a valid fixture. Positive fixtures must be accepted at their actual dimensions with the extra transport byte. See [test inputs](../tests/fixtures/README.md).

## Advance both histories only after transfer completion

Preserve the first two full frames, the union of changes against both histories, removal of the old cursor image, and checks for both libusb success and the exact completed byte count. USB completion is neither physical panel display nor a bulk-IN ACK. Do not add arbitrary retries, resets, or heartbeats to general errors.

## Preserve the configuration delay and coordinated shutdown

The 1-second delay after DQT and two resolution writes is a verified conservative value, not an established minimum. Start panels sequentially after confirming each panel's first two frames. Stop all captures before shared release, host shutdown, and vendor restoration. SIGPIPE caused by closing the host's stdout before reading its final output is also a regression condition.

## Prefer the latest capture and measure option effects

For small changes, task dispatch and GPU copying may cost more than they save. Speculative preparation is implemented, but the previous five-condition comparison did not show higher output rates. Do not describe enabling CPU/Metal, workers, or buffers indiscriminately as maximum performance. See the [algorithm guide](../artifacts/quad-monitor-algorithms.html).

## Separate native migration from physical validation

Direct Swift/C transfer removes Python relay and frame-pipe costs. User satisfaction, reconnect, and endurance results from the earlier Python version do not establish hardware success for native 0.3.0. Distinguish the 60fps cap, capture rate, USB completion rate, and physical display rate. Do not add 120Hz, hardware cursors, or other codecs without evidence.

## Keep final deliverables that remain maintainable

Retain current source, build scripts, essential tests, small fixtures, core documentation, and releases. Tests for the old Python app and experiment automation were moved to the external archive with their implementations. They were not removed because product tests failed; the [test guide](../tests/README.md) states the scope change. See the [archive guide](archive.md) for locations and restoration.

## Documentation languages

Maintain project documents in English. Provide the algorithm artifact in English, Korean, and Simplified Chinese with matching explanations, interactive behavior, measurements, and validation limits. Keep the RacerUSB origin explicit in the project README.
