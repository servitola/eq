#include "EQDriverProtocol.h"

#include <math.h>
#include <string.h>

_Static_assert(sizeof(eqc_blob_band) == 32, "no padding in a band");
_Static_assert(sizeof(eqc_blob) == 352 + 32 * EQC_MAX_BANDS, "no padding in the settings record");
_Static_assert(sizeof(eqc_meter_frame) == 32 + 3 * 8 * EQC_MAX_METER_BANDS, "no padding in the meter frame");
_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "records are little-endian in memory");

bool eqc_blob_encode(eqc_blob *out, const eqc_settings *s, const char *targetUID, uint64_t serial) {
    memset(out, 0, sizeof(*out));
    size_t length = strlen(targetUID);
    if (length == 0 || length >= EQC_BLOB_UID_CAPACITY) return false;
    out->magic = EQC_BLOB_MAGIC;
    out->version = EQC_BLOB_VERSION;
    out->size = sizeof(eqc_blob);
    out->serial = serial;
    memcpy(out->targetUID, targetUID, length);
    int32_t count = s->bandCount < 0 ? 0 : s->bandCount > EQC_MAX_BANDS ? EQC_MAX_BANDS : s->bandCount;
    out->bandCount = (uint32_t)count;
    for (int32_t i = 0; i < count; i++) {
        const eqc_band *b = &s->bands[i];
        out->bands[i] = (eqc_blob_band){(uint32_t)b->type, b->enabled, b->frequency, b->gainDB, b->q};
    }
    out->preampDB = s->preampDB;
    out->outputGainDB = s->outputGainDB;
    out->limiterEnabled = s->limiterEnabled;
    out->limiterCeilingDB = s->limiterCeilingDB;
    out->bypassed = s->bypassed;
    out->compressor = (uint32_t)s->compressor;
    out->colour = (uint32_t)s->colour;
    out->colourAmount = s->colourAmount;
    out->solo = s->solo;
    out->soloLow = s->soloLow;
    out->soloHigh = s->soloHigh;
    return true;
}

static bool within(double x, double low, double high) { return x >= low && x <= high; }
static bool flag(uint32_t x) { return x <= 1; }

static eqc_blob_status check(const eqc_blob *b) {
    if (b->magic != EQC_BLOB_MAGIC) return EQC_BLOB_BAD_MAGIC;
    if (b->version != EQC_BLOB_VERSION) return EQC_BLOB_BAD_VERSION;
    if (b->size != sizeof(eqc_blob)) return EQC_BLOB_BAD_SIZE;

    size_t length = strnlen(b->targetUID, EQC_BLOB_UID_CAPACITY);
    if (length == 0 || length == EQC_BLOB_UID_CAPACITY) return EQC_BLOB_BAD_UID;
    for (size_t i = 0; i < EQC_BLOB_UID_CAPACITY; i++) {
        unsigned char c = (unsigned char)b->targetUID[i];
        if (i < length ? c < 0x20 || c == 0x7f : c != 0) return EQC_BLOB_BAD_UID;
    }

    double values[] = {b->preampDB, b->outputGainDB, b->limiterCeilingDB, b->colourAmount, b->soloLow, b->soloHigh};
    for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); i++)
        if (!isfinite(values[i])) return EQC_BLOB_NOT_FINITE;
    for (uint32_t i = 0; i < EQC_MAX_BANDS; i++) {
        const eqc_blob_band *band = &b->bands[i];
        if (!isfinite(band->frequency) || !isfinite(band->gainDB) || !isfinite(band->q)) return EQC_BLOB_NOT_FINITE;
    }

    if (b->reserved || b->reserved2 || b->bandCount > EQC_MAX_BANDS) return EQC_BLOB_OUT_OF_RANGE;
    if (!within(b->preampDB, EQC_BLOB_MIN_GAIN_DB, EQC_BLOB_MAX_GAIN_DB) ||
        !within(b->outputGainDB, EQC_BLOB_MIN_GAIN_DB, EQC_BLOB_MAX_GAIN_DB) ||
        !within(b->limiterCeilingDB, EQC_BLOB_MIN_GAIN_DB, 0) || !within(b->colourAmount, 0, 1) ||
        !within(b->soloLow, 0, EQC_BLOB_MAX_FREQUENCY) || !within(b->soloHigh, 0, EQC_BLOB_MAX_FREQUENCY))
        return EQC_BLOB_OUT_OF_RANGE;
    if (!flag(b->limiterEnabled) || !flag(b->bypassed) || !flag(b->solo) || b->compressor > EQC_COMPRESSOR_NIGHT ||
        b->colour > EQC_COLOUR_TUBE)
        return EQC_BLOB_OUT_OF_RANGE;
    for (uint32_t i = 0; i < EQC_MAX_BANDS; i++) {
        const eqc_blob_band *band = &b->bands[i];
        if (i >= b->bandCount) {
            static const eqc_blob_band unused;
            if (memcmp(band, &unused, sizeof(unused)) != 0) return EQC_BLOB_OUT_OF_RANGE;
            continue;
        }
        if (band->type > EQC_BAND_PASS || !flag(band->enabled) ||
            !within(band->frequency, EQC_BLOB_MIN_FREQUENCY, EQC_BLOB_MAX_FREQUENCY) ||
            !within(band->gainDB, -EQC_BLOB_MAX_BAND_GAIN_DB, EQC_BLOB_MAX_BAND_GAIN_DB) ||
            !within(band->q, EQC_BLOB_MIN_Q, EQC_BLOB_MAX_Q))
            return EQC_BLOB_OUT_OF_RANGE;
    }
    return EQC_BLOB_OK;
}

eqc_blob_status eqc_blob_decode(const void *bytes, size_t size, eqc_settings *s, char *targetUID, uint64_t *serial) {
    if (size != sizeof(eqc_blob)) return EQC_BLOB_BAD_SIZE;
    eqc_blob b;
    memcpy(&b, bytes, sizeof(b));
    eqc_blob_status status = check(&b);
    if (status != EQC_BLOB_OK) return status;

    memset(s, 0, sizeof(*s));
    s->bandCount = (int32_t)b.bandCount;
    for (uint32_t i = 0; i < b.bandCount; i++) {
        const eqc_blob_band *band = &b.bands[i];
        s->bands[i] = (eqc_band){(eqc_filter_type)band->type, band->frequency, band->gainDB, band->q, band->enabled != 0};
    }
    s->preampDB = b.preampDB;
    s->outputGainDB = b.outputGainDB;
    s->limiterEnabled = b.limiterEnabled != 0;
    s->limiterCeilingDB = b.limiterCeilingDB;
    s->bypassed = b.bypassed != 0;
    s->compressor = (eqc_compressor)b.compressor;
    s->colour = (eqc_colour)b.colour;
    s->colourAmount = b.colourAmount;
    s->solo = b.solo != 0;
    s->soloLow = b.soloLow;
    s->soloHigh = b.soloHigh;
    memcpy(targetUID, b.targetUID, EQC_BLOB_UID_CAPACITY);
    *serial = b.serial;
    return EQC_BLOB_OK;
}

const char *eqc_blob_status_text(eqc_blob_status status) {
    switch (status) {
    case EQC_BLOB_OK: return "ok";
    case EQC_BLOB_BAD_SIZE: return "wrong size";
    case EQC_BLOB_BAD_MAGIC: return "not an eq settings record";
    case EQC_BLOB_BAD_VERSION: return "unknown settings version";
    case EQC_BLOB_BAD_UID: return "bad target UID";
    case EQC_BLOB_NOT_FINITE: return "a value is not finite";
    case EQC_BLOB_OUT_OF_RANGE: return "a value is out of range";
    }
    return "unknown";
}

void eqc_meter_frame_read(eqc_meter_frame *out, eqc_engine *engine, const double *frequencies, int32_t bands) {
    memset(out, 0, sizeof(*out));
    out->magic = EQC_METER_MAGIC;
    out->version = EQC_METER_VERSION;
    int32_t count = bands < 0 ? 0 : bands > EQC_MAX_METER_BANDS ? EQC_MAX_METER_BANDS : bands;
    if (engine && eqc_meter_band_count(eqc_engine_meter(engine)) != count) count = 0;
    out->bandCount = (uint16_t)count;
    for (int32_t i = 0; i < count; i++) {
        out->frequencies[i] = frequencies[i];
        out->inputDB[i] = out->outputDB[i] = EQC_METER_FLOOR_DB;
    }
    out->peakDB = EQC_METER_FLOOR_DB;
    if (!engine) return;
    eqc_meter_read(eqc_engine_meter(engine), out->inputDB, out->outputDB, &out->peakDB);
    out->limiting = eqc_limiting(engine);
    out->compressorReductionDB = eqc_compressor_reduction_db(engine);
}

bool eqc_meter_frame_decode(const void *bytes, size_t size, eqc_meter_frame *out) {
    if (size != sizeof(eqc_meter_frame)) return false;
    eqc_meter_frame f;
    memcpy(&f, bytes, sizeof(f));
    if (f.magic != EQC_METER_MAGIC || f.version != EQC_METER_VERSION || f.bandCount > EQC_MAX_METER_BANDS) return false;
    *out = f;
    return true;
}
