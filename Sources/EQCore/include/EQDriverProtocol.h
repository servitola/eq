#ifndef EQ_DRIVER_PROTOCOL_H
#define EQ_DRIVER_PROTOCOL_H

// What eq and the HAL plug-in pass each other through the plug-in's custom properties: fixed-layout,
// little-endian records with no padding, carried as CFData. The plug-in trusts none of it until
// `eqc_blob_decode` has checked every field.

#include "EQCore.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

/// "EQS1" in memory.
#define EQC_BLOB_MAGIC 0x31535145u
#define EQC_BLOB_VERSION 1
#define EQC_BLOB_UID_CAPACITY 256
/// "EQM1" in memory.
#define EQC_METER_MAGIC 0x314d5145u
#define EQC_METER_VERSION 1

// The widest values the plug-in accepts: past what eq's own config allows, short of anything that
// could only be a mistake.
#define EQC_BLOB_MIN_FREQUENCY 1.0
#define EQC_BLOB_MAX_FREQUENCY 100000.0
#define EQC_BLOB_MAX_BAND_GAIN_DB 60.0
#define EQC_BLOB_MIN_Q 0.01
#define EQC_BLOB_MAX_Q 100.0
#define EQC_BLOB_MIN_GAIN_DB (-60.0)
#define EQC_BLOB_MAX_GAIN_DB 24.0

typedef struct {
    uint32_t type, enabled;
    double frequency, gainDB, q;
} eqc_blob_band;

/// The settings for one target. `size` is the whole record's; `serial` is the writer's, handed back
/// in the plug-in's health so it can tell which settings play.
typedef struct {
    uint32_t magic;
    uint16_t version, reserved;
    uint32_t size, bandCount;
    uint64_t serial;
    /// UTF-8, NUL-terminated, zero after the NUL.
    char targetUID[EQC_BLOB_UID_CAPACITY];
    double preampDB, outputGainDB, limiterCeilingDB, colourAmount, soloLow, soloHigh;
    uint32_t limiterEnabled, bypassed, compressor, colour, solo, reserved2;
    eqc_blob_band bands[EQC_MAX_BANDS];
} eqc_blob;

typedef enum {
    EQC_BLOB_OK,
    EQC_BLOB_BAD_SIZE,
    EQC_BLOB_BAD_MAGIC,
    EQC_BLOB_BAD_VERSION,
    EQC_BLOB_BAD_UID,
    EQC_BLOB_NOT_FINITE,
    EQC_BLOB_OUT_OF_RANGE,
} eqc_blob_status;

/// False, leaving `out` zeroed, when the UID is empty or does not fit.
bool eqc_blob_encode(eqc_blob *out, const eqc_settings *settings, const char *targetUID, uint64_t serial);
/// Checks `size` bytes at `bytes` field by field. On EQC_BLOB_OK fills `settings` and `targetUID`
/// (EQC_BLOB_UID_CAPACITY bytes) and `serial`; on anything else leaves them alone.
eqc_blob_status eqc_blob_decode(const void *bytes, size_t size, eqc_settings *settings, char *targetUID, uint64_t *serial);
const char *eqc_blob_status_text(eqc_blob_status status);

/// What `eq watch` needs from one read: the meter's bands (in dB, floored at EQC_METER_FLOOR_DB),
/// the output peak, and the dynamics.
typedef struct {
    uint32_t magic;
    uint16_t version, bandCount;
    uint32_t limiting, reserved;
    double compressorReductionDB, peakDB;
    double frequencies[EQC_MAX_METER_BANDS];
    double inputDB[EQC_MAX_METER_BANDS];
    double outputDB[EQC_MAX_METER_BANDS];
} eqc_meter_frame;

/// Reads a running engine lock-free, from any thread.
void eqc_meter_frame_read(eqc_meter_frame *out, eqc_engine *_Nullable engine, const double *frequencies, int32_t bands);
bool eqc_meter_frame_decode(const void *bytes, size_t size, eqc_meter_frame *out);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
