#if __has_include(<libusb.h>)
#include <libusb.h>
#elif __has_include(<libusb-1.0/libusb.h>)
#include <libusb-1.0/libusb.h>
#else
#error "libusb header not found"
#endif
