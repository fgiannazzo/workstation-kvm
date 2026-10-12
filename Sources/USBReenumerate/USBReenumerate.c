// See include/USBReenumerate.h. Behaviour ported from the prototype's usbreset.c: match
// IOUSBHostDevice entries by vendor (and optionally product), open each through the IOUSBLib
// device user client and call USBDeviceReEnumerate. No other USB traffic is generated.
#include "USBReenumerate.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

/// Reads an integer registry property, or returns -1 when absent or not a number.
static int registry_int(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return -1;
    int result = -1;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        if (!CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result)) result = -1;
    }
    CFRelease(value);
    return result;
}

/// Opens one matched device and asks it to re-enumerate. Returns 1 on success, 0 otherwise.
static int reenumerate_one(io_service_t service) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || !plugin) return 0;

    IOUSBDeviceInterface **device = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
    (*plugin)->Release(plugin);
    if (hr != S_OK || !device) return 0;

    int ok = 0;
    if ((*device)->USBDeviceOpen(device) == kIOReturnSuccess) {
        if ((*device)->USBDeviceReEnumerate(device, 0) == kIOReturnSuccess) ok = 1;
        (*device)->USBDeviceClose(device);
    }
    (*device)->Release(device);
    return ok;
}

int usb_reenumerate_devices(uint16_t vendor_id, uint16_t product_id_or_zero) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (!matching) return -1;
    // IOServiceGetMatchingServices consumes one reference to the matching dictionary.
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) return -1;

    int matched = 0;
    int reenumerated = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        int vid = registry_int(service, CFSTR("idVendor"));
        int pid = registry_int(service, CFSTR("idProduct"));
        if (vid == vendor_id && (product_id_or_zero == 0 || pid == product_id_or_zero)) {
            matched++;
            reenumerated += reenumerate_one(service);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    if (matched > 0 && reenumerated == 0) return -2;
    return reenumerated;
}
