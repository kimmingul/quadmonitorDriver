# Current USB protocol and transfer contract

This document describes the native Swift/C transfer path and verified device contract for the observed 1920×1200 RACERTECH configuration. It does not describe every undocumented firmware capability. See [frame details](frame_format.md) and [current status](current-status.md).

## Devices and roles

| Item | Verified value |
|---|---|
| VID / PID | `0x34c7 / 0x2114` |
| Connection | One USB-C cable → internal hub → three panels, with separate power |
| Speed | USB 2.0 High-Speed; all three panels share upstream bus bandwidth |
| Interface / alternate | `0 / 0` |
| Video endpoint | bulk OUT `0x01`, max packet 512B |
| Video input | 1920×1200, 32×8 tiles, JPEG 4:4:4 container |

[Role configuration](../config/panel-layout.json) matches explicit paths against read device IDs, rather than relying on USB enumeration order or dynamic addresses.

| User's perspective | Role | Number/color | Path after September 11 ID verification | Device ID |
|---|---|---|---|---:|
| Right | right | 1 / red | `0:1.1` | 1177523011 |
| Left | left | 2 / green | `0:1.2` | 44 |
| Top | top | 3 / blue | `0:1.4` | 29126 |

The September 11 paths were updated by matching control IN `0x50` device IDs in the startup-recovery records in the [external archive](archive.md). This is not yet automatic remapping.

USB paths and CGDisplayIDs can change after re-enumeration, moving ports, or recreating displays. Do not bind a different panel by arbitrary order if paths differ. Physical validation of automatic recovery covers reconnecting to the same Mac port.

## Configuration sequence

The normal app takes over the interface owned by the vendor LaunchAgent and applies the following sequence to interface 0 / alt 0 of each selected device. It records the agent's loaded state at takeover and restores it after the session.

Control IN: `bmRequestType=0xc1`, `wIndex=0`, timeout 500ms. These are **requested lengths**; record actual length, data, and errors separately.

| bRequest | wValue | Requested bytes |
|---|---:|---:|
| `0x40` | 0 | 2 |
| `0x50` | 0 | 4 |
| `0x51` | 0 | 2 |
| `0x52` | 0 | 2 |
| `0x49` | 0 | 1 |
| `0x41` | 0 | 2 |
| `0x41` | 1 | 128 |
| `0x41` | 2 | 128 |

Use the four-byte `0x50` value for device ID matching. Do not assign unverified mode/ACK meanings to every request. Exploratory read errors in `configure` are logged and processing continues; role ID verification has a separate path.

Control OUT: `bmRequestType=0x41`, `wIndex=0`, timeout 500ms. Each of the following three writes must complete exactly its payload length.

1. `bRequest=0x83`, `wValue=1`: 138B natural-order DQT.
2. `bRequest=0x81`, `wValue=0`: `80 07 b0 04` (UInt16 LE 1920,1200).
3. Repeat the same resolution write once.
4. Record `configuration_settle` and **wait 1.0 second** before bulk transfer.

DQT is `FF DB 00 43 00` + luma64 + `FF DB 00 43 01` + chroma64. Compare values against `DQT_*_NATURAL` in the [independent codec](../tests/support/jpeg_codec.py) and [Tables.h](../App/Sources/CFrameEncoder/Tables.h). Do not send JPEG-file zigzag DQT ordering directly over USB or arbitrarily fill its end with 0x0a.

For the same valid 764,801B frame, libusb without the delay timed out after 16,384B. With a 1-second delay, both IOKit and libusb successfully sent two full frames each. See `docs/usb-transfer-differential-2026-09-07.md` in the [external archive](archive.md). This is a verified conservative setting, not a discovered minimum delay or device-ready signal.

## Frames and completion handling

A frame consists of tiles with D0/D8 headers, a footer reaching the 128B boundary, and one final extra byte. This path does not send raw JFIF/JPEG files or H.264 streams. Pass the entire frame as one contiguous buffer to one bulk write; the 512B USB packet size is not an API frame-length limit.

`VerifiedCapture` uses [NativeFrameOutput](../App/Sources/VerifiedUSB/NativeFrameOutput.swift) to validate the full length, tiles, entropy, and footer with the C validator before sending directly through libusb. The product path has no Python validator fallback.

Commit history only after libusb returns 0 and the completed byte count exactly matches the full request. This is neither a device bulk-IN ACK nor confirmation of physical panel display. The old Python relay's pipe `A` response is historical, not the current frame relay path. Partial writes and exceptions stop the session and invalidate history without committing success. Do not add arbitrary reset, clear-halt, or retries.

Keep one latest snapshot and one pending frame. The first two frames include all 9,000 tiles. Thereafter compare current BGRA against both successful histories and transmit tiles differing from either. Fully settled static screens skip video writes. Idle/heartbeat logs indicating worker liveness are not USB vendor heartbeat commands.

## Lifetime and recovery

Start the next capture after the selected panel's first two full frames complete. Stop proceeds through: confirm all captures stopped → shared release → helper exit → removal of host-owned displays → vendor restoration. Preserve this barrier because terminating an early-finishing helper previously caused framework failures in other captures.

The app starts a new session after confirmed USB absence or sleep if run intent remains. Stop/Quit cancels resumption. A general I/O error alone is not evidence of reconnection. Actual recovery was verified on September 8, but pre-sleep `stopCapture` misuse/timeouts remained, and physical revalidation of the latest options build is incomplete.

## Historical hypotheses outside the current contract

A fixed 8KB firmware wall, mandatory alt1, mandatory periodic vendor heartbeat, class-independent meanings of raw selector numbers, removing `+1`, and support for unverified codecs are not part of the current contract. Evidence is retained in the September 7 audit in the [external archive](archive.md). The [performance algorithms](../artifacts/quad-monitor-algorithms.html) preserve this transfer format and completion contract.
