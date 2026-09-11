#ifndef IOKIT_USB_H
#define IOKIT_USB_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque per-device handle.
typedef struct iokit_usb_device iokit_usb_device_t;

// IOReturn codes are macOS-specific 32-bit values; we expose them as int32_t.
// 0 = kIOReturnSuccess. The bulk-write helper also surfaces partial transfers.

// Open all USB devices matching (vid, pid). On success returns the count and
// fills `out_devices` with up to `max_devices` opened device handles. The
// caller must release each handle via iokit_usb_close.
//
// Returns the number of devices opened on success, or a negative value on
// failure (kIOReturnError or similar). Devices that fail to open mid-iteration
// are skipped silently — the count reflects only successful opens.
int iokit_usb_open_matching(
    uint16_t vid,
    uint16_t pid,
    iokit_usb_device_t **out_devices,
    int max_devices,
    char *err_message,
    int err_message_len
);

void iokit_usb_close(iokit_usb_device_t *dev);

// Bus + address (for diagnostic logging).
uint8_t iokit_usb_bus_number(const iokit_usb_device_t *dev);
uint8_t iokit_usb_device_address(const iokit_usb_device_t *dev);

// Vendor IN control transfer. bmRequestType is fixed to 0xC1
// (IN | Vendor | Interface). Returns >=0 = bytes received, <0 = IOReturn.
int32_t iokit_usb_vendor_in(
    iokit_usb_device_t *dev,
    uint8_t bRequest,
    uint16_t wValue,
    uint8_t *buffer,
    uint16_t wLength,
    uint32_t timeout_ms
);

// Vendor OUT control transfer. bmRequestType is fixed to 0x41
// (OUT | Vendor | Interface). Returns 0 on success, IOReturn on failure.
int32_t iokit_usb_vendor_out(
    iokit_usb_device_t *dev,
    uint8_t bRequest,
    uint16_t wValue,
    const uint8_t *payload,
    uint16_t wLength,
    uint32_t timeout_ms
);

// Bulk write via WritePipeTO with the original app's recovery pattern:
// on kIOReturnNotResponding, call AbortPipe + ResetPipe and retry up to
// `max_retries` times (matching the disassembly of UsbDisplay.app's
// Write:length: at 0x100009c78). Returns 0 on success or final IOReturn.
// `*transferred` is the byte count from the last WritePipeTO call.
//
// IMPORTANT: WritePipeTO clamps to the actual buffer size, so passing
// `size + 1` (as the original app does) is harmless — an extra byte never
// reaches the wire. We pass `size` exactly to avoid relying on that.
int32_t iokit_usb_bulk_write(
    iokit_usb_device_t *dev,
    uint8_t pipe_ref,
    const uint8_t *buffer,
    uint32_t size,
    uint32_t no_data_timeout_ms,
    uint32_t completion_timeout_ms,
    int max_retries,
    uint32_t *transferred
);

// Bulk read via ReadPipeTO on `pipe_ref`. Mirrors UsbDisplay's recovery
// pattern from fn_100015c64 (lldb-unnamed symbol): on WritePipeTO error
// 0xE000_404F, the app issues SetPipePolicy(pipeRef) + sleep(0) +
// ReadPipe(pipeRef) up to 2 times. We expose ReadPipeTO standalone so it
// can be called as a *prereq* (before bulk OUT) or *recovery* (after) to
// test whether driving the pipe in both directions triggers the firmware
// ring drain. Returns IOReturn from ReadPipeTO; `*transferred` is bytes
// received. Note: on an OUT-only endpoint, the kernel may reject this —
// non-zero rc is informational, not an error.
int32_t iokit_usb_bulk_read(
    iokit_usb_device_t *dev,
    uint8_t pipe_ref,
    uint8_t *buffer,
    uint32_t size,
    uint32_t no_data_timeout_ms,
    uint32_t completion_timeout_ms,
    uint32_t *transferred
);

// Diagnostic helpers — issue a single AbortPipe or ResetPipe call.
int32_t iokit_usb_abort_pipe(iokit_usb_device_t *dev, uint8_t pipe_ref);
int32_t iokit_usb_reset_pipe(iokit_usb_device_t *dev, uint8_t pipe_ref);
int32_t iokit_usb_clear_pipe_stall(iokit_usb_device_t *dev, uint8_t pipe_ref);

#ifdef __cplusplus
}
#endif

#endif
