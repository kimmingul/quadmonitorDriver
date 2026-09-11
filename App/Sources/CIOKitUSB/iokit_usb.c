#include "iokit_usb.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct iokit_usb_device {
    IOUSBDeviceInterface500 **device;
    IOUSBInterfaceInterface500 **interface;
    uint8_t bus_number;
    uint8_t device_address;
    // Async machinery — required by WritePipeTO/ReadPipeTO/ControlRequestTO
    // for the timeout mechanism. The source must be on a *running* runloop.
    CFRunLoopSourceRef async_source;
    pthread_t runloop_thread;
    CFRunLoopRef worker_runloop;
};

static void *runloop_thread_main(void *ctx) {
    struct iokit_usb_device *dev = (struct iokit_usb_device *)ctx;
    dev->worker_runloop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(dev->worker_runloop, dev->async_source, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    return NULL;
}

static void copy_err(char *dst, int len, const char *src) {
    if (!dst || len <= 0) return;
    strncpy(dst, src ? src : "", (size_t)len - 1);
    dst[len - 1] = '\0';
}

static int32_t open_one_device(
    io_service_t service,
    iokit_usb_device_t *out
) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn rc;

    rc = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    if (rc != kIOReturnSuccess || plugin == NULL) {
        return rc != 0 ? rc : kIOReturnError;
    }

    IOUSBDeviceInterface500 **deviceIntf = NULL;
    HRESULT qrc = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500),
        (LPVOID *)&deviceIntf
    );
    (*plugin)->Release(plugin);
    if (qrc != 0 || deviceIntf == NULL) {
        return kIOReturnError;
    }

    rc = (*deviceIntf)->USBDeviceOpen(deviceIntf);
    if (rc != kIOReturnSuccess) {
        (*deviceIntf)->Release(deviceIntf);
        return rc;
    }

    UInt8 numConfig = 0;
    (*deviceIntf)->GetNumberOfConfigurations(deviceIntf, &numConfig);
    IOUSBConfigurationDescriptorPtr cfg = NULL;
    if (numConfig > 0) {
        (*deviceIntf)->GetConfigurationDescriptorPtr(deviceIntf, 0, &cfg);
        if (cfg) {
            UInt8 cur = 0;
            (*deviceIntf)->GetConfiguration(deviceIntf, &cur);
            if (cur != cfg->bConfigurationValue) {
                (*deviceIntf)->SetConfiguration(deviceIntf, cfg->bConfigurationValue);
            }
        }
    }

    UInt32 location = 0;
    (*deviceIntf)->GetLocationID(deviceIntf, &location);

    UInt8 address = 0;
    (*deviceIntf)->GetDeviceAddress(deviceIntf, (USBDeviceAddress *)&address);

    // Iterate interfaces and grab the first one with at least one bulk OUT
    // endpoint. The RACERTECH USB DISP advertises a single interface with
    // exactly 1 endpoint (bulk OUT 0x01).
    IOUSBFindInterfaceRequest req = {
        .bInterfaceClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceSubClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceProtocol = kIOUSBFindInterfaceDontCare,
        .bAlternateSetting = kIOUSBFindInterfaceDontCare,
    };
    io_iterator_t intfIter = 0;
    rc = (*deviceIntf)->CreateInterfaceIterator(deviceIntf, &req, &intfIter);
    if (rc != kIOReturnSuccess) {
        (*deviceIntf)->USBDeviceClose(deviceIntf);
        (*deviceIntf)->Release(deviceIntf);
        return rc;
    }

    io_service_t intfService = IOIteratorNext(intfIter);
    IOObjectRelease(intfIter);
    if (intfService == 0) {
        (*deviceIntf)->USBDeviceClose(deviceIntf);
        (*deviceIntf)->Release(deviceIntf);
        return kIOReturnNoDevice;
    }

    IOCFPlugInInterface **intfPlugin = NULL;
    rc = IOCreatePlugInInterfaceForService(
        intfService,
        kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &intfPlugin,
        &score
    );
    IOObjectRelease(intfService);
    if (rc != kIOReturnSuccess || intfPlugin == NULL) {
        (*deviceIntf)->USBDeviceClose(deviceIntf);
        (*deviceIntf)->Release(deviceIntf);
        return rc != 0 ? rc : kIOReturnError;
    }

    IOUSBInterfaceInterface500 **intf = NULL;
    qrc = (*intfPlugin)->QueryInterface(
        intfPlugin,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID500),
        (LPVOID *)&intf
    );
    (*intfPlugin)->Release(intfPlugin);
    if (qrc != 0 || intf == NULL) {
        (*deviceIntf)->USBDeviceClose(deviceIntf);
        (*deviceIntf)->Release(deviceIntf);
        return kIOReturnError;
    }

    rc = (*intf)->USBInterfaceOpen(intf);
    if (rc != kIOReturnSuccess) {
        (*intf)->Release(intf);
        (*deviceIntf)->USBDeviceClose(deviceIntf);
        (*deviceIntf)->Release(deviceIntf);
        return rc;
    }

    // SetAlternateInterface(1) intentionally NOT called: alt 1 is not in
    // the device's published descriptor (libusb confirms only alt 0) —
    // SetAlternateInterface(1) returns kIOReturnNotFound. SetPipePolicy()
    // returns kIOReturnBadArgument on macOS 26 even with EP-matching
    // mps/interval values (verified 2026-04-26 session #3, GetPipeProperties
    // confirmed mps=512, interval=0; SetPipePolicy(512, 0) -> 0xE00002C2).
    //
    // sel=5 [1] / sel=4 [0] ring-token attempts (session #3): IOUSBLib
    // classic plug-in already auto-emits sel=4 [0] ×2 + sel=0 [0] + sel=3
    // + sel=8 during USBDeviceOpen (verified via lldb trace 2026-04-26).
    // Adding more sel=4 [0] dispatches on extra raw IOServiceOpen conns
    // does NOT change cap=8K. UsbDisplay's true cap-fix mechanism likely
    // lives in graphics-side calls (sel=271/sel=274/sel=10 on
    // IOSurfaceRoot / AGXAcceleratorG17X) that mediate USB-DMA buffer
    // backing — beyond the scope of this transport.

    // ControlRequestTO and WritePipeTO use the interface's async port to
    // implement their timeout logic. Without it, transfers that don't
    // complete on the fast path return kIOUSBNoAsyncPortErr (0xE0004051).
    // The CFRunLoopSource the API hands us must be on a *running* runloop —
    // we spawn a dedicated background thread to host it.
    CFRunLoopSourceRef src = NULL;
    IOReturn srcRc = (*intf)->CreateInterfaceAsyncEventSource(intf, &src);
    if (srcRc != kIOReturnSuccess || src == NULL) {
        fprintf(stderr, "[CIOKitUSB] CreateInterfaceAsyncEventSource rc=0x%X\n", srcRc);
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        (*deviceIntf)->USBDeviceClose(deviceIntf);
        (*deviceIntf)->Release(deviceIntf);
        return srcRc;
    }

    out->device = deviceIntf;
    out->interface = intf;
    out->bus_number = (uint8_t)((location >> 24) & 0xFF);
    out->device_address = address;
    out->async_source = src;
    out->worker_runloop = NULL;

    int prc = pthread_create(&out->runloop_thread, NULL, runloop_thread_main, out);
    if (prc != 0) {
        fprintf(stderr, "[CIOKitUSB] pthread_create failed errno=%d\n", prc);
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        (*deviceIntf)->USBDeviceClose(deviceIntf);
        (*deviceIntf)->Release(deviceIntf);
        return kIOReturnError;
    }

    // Give the runloop thread a moment to attach the source — without this
    // the very first WritePipeTO can race the runloop start.
    usleep(20 * 1000);
    return kIOReturnSuccess;
}

int iokit_usb_open_matching(
    uint16_t vid,
    uint16_t pid,
    iokit_usb_device_t **out_devices,
    int max_devices,
    char *err_message,
    int err_message_len
) {
    if (out_devices == NULL || max_devices <= 0) {
        copy_err(err_message, err_message_len, "invalid arguments");
        return -1;
    }

    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (matching == NULL) {
        copy_err(err_message, err_message_len, "IOServiceMatching returned NULL");
        return -1;
    }

    SInt32 vidS = vid;
    SInt32 pidS = pid;
    CFNumberRef vidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vidS);
    CFNumberRef pidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pidS);
    CFDictionarySetValue(matching, CFSTR(kUSBVendorID), vidNum);
    CFDictionarySetValue(matching, CFSTR(kUSBProductID), pidNum);
    CFRelease(vidNum);
    CFRelease(pidNum);

    io_iterator_t iter = 0;
    kern_return_t rc = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter);
    if (rc != KERN_SUCCESS) {
        copy_err(err_message, err_message_len, "IOServiceGetMatchingServices failed");
        return -1;
    }

    int opened = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iter)) != 0 && opened < max_devices) {
        iokit_usb_device_t *dev = (iokit_usb_device_t *)calloc(1, sizeof(iokit_usb_device_t));
        if (!dev) {
            IOObjectRelease(service);
            break;
        }
        int32_t orc = open_one_device(service, dev);
        IOObjectRelease(service);
        if (orc != kIOReturnSuccess) {
            free(dev);
            continue;
        }
        out_devices[opened++] = dev;
    }
    IOObjectRelease(iter);
    return opened;
}

void iokit_usb_close(iokit_usb_device_t *dev) {
    if (!dev) return;
    if (dev->worker_runloop) {
        CFRunLoopStop(dev->worker_runloop);
        pthread_join(dev->runloop_thread, NULL);
    }
    if (dev->async_source) {
        CFRelease(dev->async_source);
    }
    if (dev->interface) {
        (*dev->interface)->USBInterfaceClose(dev->interface);
        (*dev->interface)->Release(dev->interface);
    }
    if (dev->device) {
        (*dev->device)->USBDeviceClose(dev->device);
        (*dev->device)->Release(dev->device);
    }
    free(dev);
}

uint8_t iokit_usb_bus_number(const iokit_usb_device_t *dev) {
    return dev ? dev->bus_number : 0;
}

uint8_t iokit_usb_device_address(const iokit_usb_device_t *dev) {
    return dev ? dev->device_address : 0;
}

int32_t iokit_usb_vendor_in(
    iokit_usb_device_t *dev,
    uint8_t bRequest,
    uint16_t wValue,
    uint8_t *buffer,
    uint16_t wLength,
    uint32_t timeout_ms
) {
    if (!dev || !dev->device) return kIOReturnNotOpen;
    IOUSBDevRequestTO req = {0};
    req.bmRequestType = 0xC1;
    req.bRequest = bRequest;
    req.wValue = wValue;
    req.wIndex = 0;
    req.wLength = wLength;
    req.pData = buffer;
    req.noDataTimeout = timeout_ms;
    req.completionTimeout = timeout_ms;

    // Route via DEVICE conn (sel=7) to match UsbDisplay launch trace.
    IOReturn rc = (*dev->device)->DeviceRequestTO(dev->device, &req);
    if (rc != kIOReturnSuccess) return rc;
    return (int32_t)req.wLenDone;
}

int32_t iokit_usb_vendor_out(
    iokit_usb_device_t *dev,
    uint8_t bRequest,
    uint16_t wValue,
    const uint8_t *payload,
    uint16_t wLength,
    uint32_t timeout_ms
) {
    if (!dev || !dev->device) return kIOReturnNotOpen;
    IOUSBDevRequestTO req = {0};
    req.bmRequestType = 0x41;
    req.bRequest = bRequest;
    req.wValue = wValue;
    req.wIndex = 0;
    req.wLength = wLength;
    req.pData = (void *)payload;
    req.noDataTimeout = timeout_ms;
    req.completionTimeout = timeout_ms;

    // Route via DEVICE conn (sel=6) to match UsbDisplay launch trace.
    return (*dev->device)->DeviceRequestTO(dev->device, &req);
}

// Context shared between the calling thread and the WritePipe worker.
typedef struct {
    iokit_usb_device_t *dev;
    uint8_t pipe_ref;
    const uint8_t *buffer;
    uint32_t size;
    uint32_t no_data_timeout_ms;
    uint32_t completion_timeout_ms;
    IOReturn result;
    bool done;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} bulk_write_ctx_t;

static void *bulk_write_worker(void *arg) {
    bulk_write_ctx_t *ctx = (bulk_write_ctx_t *)arg;
    // WritePipeTO emits sel=7 with [pipeRef, 0, noDataTO, completionTO,
    // ptr, len, 1]. The two timeout scalars let the kernel wait for the
    // 16-packet bulk OUT ring to drain — without them (timeout=0) the
    // kernel immediately NAKs once the ring fills, capping us at
    // 8 KB = 16 × 512 B MPS. Verified by lldb-trace comparison vs
    // UsbDisplay (2026-04-26): UsbDisplay's WritePipeTO = 500/500 ms,
    // our prior plain WritePipe = 0/0 ms. Async event source is set up
    // in iokit_usb_open_matching so NoAsyncPortErr does not occur.
    IOReturn rc = (*ctx->dev->interface)->WritePipeTO(
        ctx->dev->interface,
        ctx->pipe_ref,
        (void *)ctx->buffer,
        ctx->size,
        ctx->no_data_timeout_ms,
        ctx->completion_timeout_ms
    );
    pthread_mutex_lock(&ctx->mutex);
    ctx->result = rc;
    ctx->done = true;
    pthread_cond_signal(&ctx->cond);
    pthread_mutex_unlock(&ctx->mutex);
    return NULL;
}

int32_t iokit_usb_bulk_write(
    iokit_usb_device_t *dev,
    uint8_t pipe_ref,
    const uint8_t *buffer,
    uint32_t size,
    uint32_t no_data_timeout_ms,
    uint32_t completion_timeout_ms,
    int max_retries,
    uint32_t *transferred
) {
    if (!dev || !dev->interface) return kIOReturnNotOpen;
    if (transferred) *transferred = 0;

    bulk_write_ctx_t ctx = {
        .dev = dev,
        .pipe_ref = pipe_ref,
        .buffer = buffer,
        .size = size,
        .no_data_timeout_ms = no_data_timeout_ms,
        .completion_timeout_ms = completion_timeout_ms,
        .result = 0,
        .done = false,
    };
    pthread_mutex_init(&ctx.mutex, NULL);
    pthread_cond_init(&ctx.cond, NULL);

    pthread_t tid;
    int prc = pthread_create(&tid, NULL, bulk_write_worker, &ctx);
    if (prc != 0) {
        pthread_cond_destroy(&ctx.cond);
        pthread_mutex_destroy(&ctx.mutex);
        return kIOReturnError;
    }

    // Compute absolute deadline.
    uint32_t timeout_ms = no_data_timeout_ms == 0 ? 5000 : no_data_timeout_ms;
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    uint64_t total_ns = (uint64_t)deadline.tv_nsec + (uint64_t)timeout_ms * 1000000ULL;
    deadline.tv_sec += (time_t)(total_ns / 1000000000ULL);
    deadline.tv_nsec = (long)(total_ns % 1000000000ULL);

    pthread_mutex_lock(&ctx.mutex);
    while (!ctx.done) {
        int wrc = pthread_cond_timedwait(&ctx.cond, &ctx.mutex, &deadline);
        if (wrc == ETIMEDOUT) break;
    }
    bool timed_out = !ctx.done;
    pthread_mutex_unlock(&ctx.mutex);

    if (timed_out) {
        // Force WritePipe to return by aborting the pipe — mirrors the
        // disassembly of UsbDisplay.app's Write:length: recovery path.
        (*dev->interface)->AbortPipe(dev->interface, pipe_ref);
        // Wait for the worker to actually complete (AbortPipe wakes it).
        pthread_join(tid, NULL);
        ctx.result = kIOReturnNotResponding;
    } else {
        pthread_join(tid, NULL);
    }

    pthread_cond_destroy(&ctx.cond);
    pthread_mutex_destroy(&ctx.mutex);

    if (transferred) {
        // Synchronous WritePipe doesn't surface a partial-byte count; we
        // report `size` on full success and 0 on any failure or timeout.
        *transferred = (ctx.result == kIOReturnSuccess) ? size : 0;
    }
    if (ctx.result == kIOReturnSuccess) return ctx.result;

    // Recovery: AbortPipe + ResetPipe to clean host-side queue state for the
    // *next* write. We do NOT mask the original failure — the caller needs
    // to know the data didn't reach the wire. Mirrors the original app's
    // disassembly except for the return value (the original swallows the
    // error).
    for (int i = 0; i < max_retries; i++) {
        (*dev->interface)->AbortPipe(dev->interface, pipe_ref);
        usleep(0);
        (*dev->interface)->ResetPipe(dev->interface, pipe_ref);
    }
    return ctx.result;
}

int32_t iokit_usb_bulk_read(
    iokit_usb_device_t *dev,
    uint8_t pipe_ref,
    uint8_t *buffer,
    uint32_t size,
    uint32_t no_data_timeout_ms,
    uint32_t completion_timeout_ms,
    uint32_t *transferred
) {
    if (!dev || !dev->interface) return kIOReturnNotOpen;
    if (transferred) *transferred = 0;
    if (!buffer || size == 0) return kIOReturnBadArgument;

    // ReadPipeTO takes `size` as an in/out param — kernel writes the
    // received byte count back. Use a stack-local UInt32 so the user's
    // `transferred` is only assigned on the success path.
    UInt32 ioSize = size;
    IOReturn rc = (*dev->interface)->ReadPipeTO(
        dev->interface,
        pipe_ref,
        buffer,
        &ioSize,
        no_data_timeout_ms,
        completion_timeout_ms
    );
    if (transferred) *transferred = (uint32_t)ioSize;
    return rc;
}

int32_t iokit_usb_abort_pipe(iokit_usb_device_t *dev, uint8_t pipe_ref) {
    if (!dev || !dev->interface) return kIOReturnNotOpen;
    return (*dev->interface)->AbortPipe(dev->interface, pipe_ref);
}

int32_t iokit_usb_reset_pipe(iokit_usb_device_t *dev, uint8_t pipe_ref) {
    if (!dev || !dev->interface) return kIOReturnNotOpen;
    return (*dev->interface)->ResetPipe(dev->interface, pipe_ref);
}

int32_t iokit_usb_clear_pipe_stall(iokit_usb_device_t *dev, uint8_t pipe_ref) {
    if (!dev || !dev->interface) return kIOReturnNotOpen;
    return (*dev->interface)->ClearPipeStall(dev->interface, pipe_ref);
}
