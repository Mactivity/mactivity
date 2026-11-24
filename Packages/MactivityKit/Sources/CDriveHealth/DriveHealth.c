// Drive health over NVMe SMART (D-157): public IOKit (NVMeSMARTLibExternal.h), read-only.
#include "CDriveHealth.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>

static void copy_string_property(io_object_t service, CFStringRef key, char *out, size_t size) {
    out[0] = 0;
    CFTypeRef value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key, kCFAllocatorDefault,
                                                      kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (value == NULL) {
        return;
    }
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)value, out, (CFIndex)size, kCFStringEncodingUTF8);
    }
    CFRelease(value);
}

/// "Physical Interconnect Location" in the controller's protocol characteristics.
static int32_t is_internal(io_object_t service) {
    CFTypeRef value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("Protocol Characteristics"),
                                                      kCFAllocatorDefault,
                                                      kIORegistryIterateRecursively | kIORegistryIterateParents);
    int32_t internal = 0;
    if (value != NULL && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
        CFTypeRef location = CFDictionaryGetValue((CFDictionaryRef)value, CFSTR("Physical Interconnect Location"));
        internal = location != NULL && CFGetTypeID(location) == CFStringGetTypeID()
            && CFStringCompare((CFStringRef)location, CFSTR("Internal"), 0) == kCFCompareEqualTo;
    }
    if (value != NULL) {
        CFRelease(value);
    }
    return internal;
}

static int read_smart(io_object_t service, NVMeSMARTData *data) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score)
            != KERN_SUCCESS || plugin == NULL) {
        return 0;
    }
    IONVMeSMARTInterface **smart = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    int ok = 0;
    if (smart != NULL) {
        memset(data, 0, sizeof(*data));
        ok = (*smart)->SMARTReadData(smart, data) == kIOReturnSuccess;
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
    return ok;
}

int32_t mactivity_drive_health(MactivityDriveHealth *drives, int32_t capacity) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"), &iterator)
            != KERN_SUCCESS) {
        return 0;
    }
    int32_t count = 0;
    io_object_t service;
    while ((service = IOIteratorNext(iterator)) != 0) {
        NVMeSMARTData data;
        if (count < capacity && read_smart(service, &data)) {
            MactivityDriveHealth *drive = &drives[count];
            memset(drive, 0, sizeof(*drive));
            copy_string_property(service, CFSTR("Model Number"), drive->model, sizeof(drive->model));
            drive->isInternal = is_internal(service);
            drive->percentUsed = data.PERCENTAGE_USED;
            drive->availableSpare = data.AVAILABLE_SPARE;
            drive->spareThreshold = data.AVAILABLE_SPARE_THRESHOLD;
            drive->criticalWarning = data.CRITICAL_WARNING;
            drive->temperatureKelvin = data.TEMPERATURE;
            drive->unitsRead = data.DATA_UNITS_READ[0];
            drive->unitsWritten = data.DATA_UNITS_WRITTEN[0];
            drive->powerOnHours = data.POWER_ON_HOURS[0];
            drive->powerCycles = data.POWER_CYCLES[0];
            drive->unsafeShutdowns = data.UNSAFE_SHUTDOWNS[0];
            drive->mediaErrors = data.MEDIA_ERRORS[0];
            count += 1;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}
