// IOAVServiceShim: declarations of the private IOAVService entry points used for DDC/CI over the
// video cable on Apple Silicon. The symbols are exported by IOKit; this target only declares them
// (exactly as the reference prototype ddcvcp.m does) and links the framework.
//
// Memory management: the declarations sit inside an ARC CF audit region and the create function is
// annotated CF_RETURNS_RETAINED, so Swift owns the returned reference and releases it with the
// wrapper object. The EDID out-parameter is likewise +1 ("Copy").
#ifndef IOAVSERVICESHIM_H
#define IOAVSERVICESHIM_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>

typedef CFTypeRef IOAVServiceRef;

#pragma clang arc_cf_code_audited begin

/// Creates an IOAVService for a `DCPAVServiceProxy` registry entry. Returns NULL on failure.
extern IOAVServiceRef _Nullable IOAVServiceCreateWithService(CFAllocatorRef _Nullable allocator,
                                                             io_service_t service) CF_RETURNS_RETAINED;

/// Copies the display's EDID (128 bytes or more) into `edid`.
extern IOReturn IOAVServiceCopyEDID(IOAVServiceRef _Nonnull service,
                                    CFDataRef _Nullable * _Nonnull CF_RETURNS_RETAINED edid);

/// Reads `length` bytes from the I2C device at `chipAddress` (0x37 for DDC/CI), using `dataAddress`
/// as the DDC source address (0x51 standard, 0x50 LG side channel).
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef _Nonnull service,
                                   uint32_t chipAddress,
                                   uint32_t dataAddress,
                                   void * _Nonnull buffer,
                                   uint32_t length);

/// Writes `length` bytes to the I2C device at `chipAddress`; see IOAVServiceReadI2C for the addresses.
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef _Nonnull service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void * _Nonnull buffer,
                                    uint32_t length);

#pragma clang arc_cf_code_audited end

#endif /* IOAVSERVICESHIM_H */
