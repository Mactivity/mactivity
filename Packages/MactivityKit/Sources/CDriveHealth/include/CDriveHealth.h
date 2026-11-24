// NVMe SMART health for Mactivity's drive health (D-157), through IOKit's public
// NVMeSMARTLibExternal.h. A C shim because that header isn't in IOKit's Swift module map.
#ifndef CDRIVEHEALTH_H
#define CDRIVEHEALTH_H

#include <stdint.h>

typedef struct {
    char model[96];
    int32_t isInternal;
    /// NVMe "Percentage Used": the vendor's estimate of life used, 0 to 255.
    int32_t percentUsed;
    int32_t availableSpare;
    int32_t spareThreshold;
    int32_t criticalWarning;
    int32_t temperatureKelvin;
    /// In NVMe data units of 512,000 bytes.
    uint64_t unitsRead;
    uint64_t unitsWritten;
    uint64_t powerOnHours;
    uint64_t powerCycles;
    uint64_t unsafeShutdowns;
    uint64_t mediaErrors;
} MactivityDriveHealth;

/// Fills up to `capacity` drives that answer NVMe SMART and returns how many it filled.
/// Needs no privileges: the user client is open to any process for reading.
int32_t mactivity_drive_health(MactivityDriveHealth *drives, int32_t capacity);

#endif
