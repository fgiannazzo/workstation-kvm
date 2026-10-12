// USBReenumerate: re-enumerate a USB device from software through IOUSBLib, so the LG monitor's
// HID bridge MCU starts clean when it has gone quiet (brief, section 3, "USB HID bridge").
// Ported from the prototype's usbreset.c; this is a plain C target so the IOCFPlugIn and
// IOUSBDeviceInterface vtable calls stay out of Swift.
#ifndef USBREENUMERATE_H
#define USBREENUMERATE_H

#include <stdint.h>

/// Opens every `IOUSBHostDevice` whose `idVendor` equals `vendor_id` (and whose `idProduct`
/// equals `product_id_or_zero` when that is non-zero) and asks it to re-enumerate with
/// `USBDeviceReEnumerate`.
///
/// Returns the number of devices that were successfully asked to re-enumerate (0 when none
/// matched). Negative on a hard error:
///   -1  the IOKit service matching itself failed (nothing was attempted);
///   -2  devices matched, but none could be opened or re-enumerated (another client may hold
///       the device, or the plug-in interface could not be created).
int usb_reenumerate_devices(uint16_t vendor_id, uint16_t product_id_or_zero);

#endif /* USBREENUMERATE_H */
