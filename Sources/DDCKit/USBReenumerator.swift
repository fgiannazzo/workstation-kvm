import USBReenumerate

/// Software re-enumeration of the LG USB bridge (prototype `usbreset.c`), for when the bridge
/// MCU goes quiet. Diagnostics and recovery only; it sends no DDC traffic.
public enum USBReenumerator {
    /// Asks every LG bridge (vendor 0x043E, product 0x9A39) to re-enumerate and returns how
    /// many were asked. 0 means none matched. Throws `DDCError.ioKit` when IOKit matching
    /// failed or when devices matched but none could be opened.
    public static func reenumerateLGBridge() throws -> Int {
        let result = usb_reenumerate_devices(UInt16(LGUSBBridge.vendorID), UInt16(LGUSBBridge.productID))
        guard result >= 0 else {
            let operation = result == -2
                ? "USBDeviceOpen/USBDeviceReEnumerate (matched a bridge but could not open it)"
                : "IOServiceGetMatchingServices(IOUSBHostDevice)"
            throw DDCError.ioKit(result, operation: operation)
        }
        return Int(result)
    }
}
