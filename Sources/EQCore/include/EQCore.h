#ifndef EQ_CORE_H
#define EQ_CORE_H

// eq's realtime DSP, shared by the daemon and the HAL plug-in. C11; no allocation, no locks, and
// the render thread calls nothing outside libm. The caller owns all memory: size an `eqc_engine` or `eqc_meter` with its
// `_size()` function and align it to 16 bytes.
//
// Threads. An engine has one publisher thread (`eqc_update`), one render thread (`eqc_process`,
// `eqc_reset_render_state`) and any number of readers (the getters and `eqc_meter_read`).
// `eqc_engine_init` and `eqc_configure` need both others idle. `eqc_update` never blocks the render
// thread: it fills a spare slot of a triple buffer that the next `eqc_process` picks up whole.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define EQC_MAX_CHANNELS 16
#define EQC_MAX_BANDS 64
#define EQC_MAX_METER_BANDS 16
/// The longest `eqc_process` call that is metered; a longer one plays but goes unmetered.
#define EQC_METER_CAPACITY 4096
#define EQC_METER_FLOOR_DB (-60.0)

/// The detector's ITU-R BS.1770 K-weighting: a high shelf, then a high-pass.
#define EQC_K_SHELF_FREQUENCY 1681.974450955533
#define EQC_K_SHELF_GAIN_DB 3.999843853973347
#define EQC_K_SHELF_Q 0.7071752369554196
#define EQC_K_HIGH_PASS_FREQUENCY 38.13547087602444
#define EQC_K_HIGH_PASS_Q 0.5003270373238773
#define EQC_FOLLOW_GATE_BELOW_THRESHOLD 30.0f
#define EQC_MAX_MAKEUP_DB 6.0f

typedef enum { EQC_PEAK, EQC_LOW_SHELF, EQC_HIGH_SHELF, EQC_LOW_PASS, EQC_HIGH_PASS, EQC_NOTCH, EQC_BAND_PASS } eqc_filter_type;
typedef enum { EQC_COMPRESSOR_OFF, EQC_COMPRESSOR_GENTLE, EQC_COMPRESSOR_NIGHT } eqc_compressor;
typedef enum { EQC_COLOUR_OFF, EQC_COLOUR_TAPE, EQC_COLOUR_TUBE } eqc_colour;

typedef struct {
    eqc_filter_type type;
    double frequency, gainDB, q;
    bool enabled;
} eqc_band;

/// Everything that decides the sound. `bands` run in order: the graphic bands, the filters, then
/// the preference shelves and instrument knobs as the daemon expands them. Bands past
/// `EQC_MAX_BANDS` are ignored.
typedef struct {
    eqc_band bands[EQC_MAX_BANDS];
    int32_t bandCount;
    double preampDB, outputGainDB;
    bool limiterEnabled;
    double limiterCeilingDB;
    /// Off: no EQ, no dynamics, no limiter, unless a solo range is set.
    bool bypassed;
    eqc_compressor compressor;
    eqc_colour colour;
    /// 0...1; 0 turns the colour off.
    double colourAmount;
    /// Listen to soloLow...soloHigh Hz only, clamped to 20 Hz...0.45 × the sample rate.
    bool solo;
    double soloLow, soloHigh;
} eqc_settings;

/// Normalised (a0 == 1), transposed direct form II.
typedef struct { float b0, b1, b2, a1, a2; } eqc_biquad;
typedef struct { float z1, z2; } eqc_biquad_state;

typedef struct {
    double ratio, threshold, knee, attack, release, window;
    /// The level a fixed makeup restores exactly; NaN for a makeup that follows the reduction.
    double reference;
} eqc_compressor_settings;

/// The compressor and colour stage's coefficients, as `eqc_dynamics_design` makes them.
typedef struct {
    bool compressor;
    eqc_biquad detectorShelf, detectorHighPass;
    float detectorSmoothing, attack, release, threshold, knee;
    /// 1/ratio − 1.
    float slope;
    /// The fixed makeup, when `makeupFollow` is 0.
    float makeupDB, makeupGlide;
    /// The pole of the averaged reduction a following makeup gives back; 0 for a fixed makeup.
    float makeupFollow, followGateDB;
    float glide;
    eqc_colour colour;
    float drive, inverseDrive, bias, biasOffset, biasNormal, dcPole;
} eqc_dynamics;

typedef struct {
    float meanSquare, reductionDB, averageReductionDB, makeupDB;
    /// The colour running, which may still be gliding out while another waits.
    eqc_colour colour;
    float drive;
} eqc_dynamics_state;

/// One channel's samples, non-interleaved.
typedef float *_Nonnull eqc_channel;
typedef struct eqc_engine eqc_engine;
typedef struct eqc_meter eqc_meter;

// Coefficients. Any thread.

/// RBJ Audio-EQ-Cookbook. The frequency is clamped to 1 Hz...0.499 × rate, the Q to 0.025 and up.
eqc_biquad eqc_design(eqc_filter_type type, double frequency, double gainDB, double q, double sampleRate);
/// Both poles strictly inside the unit circle.
bool eqc_biquad_is_stable(eqc_biquad c);
float eqc_biquad_process(eqc_biquad_state *state, float x, eqc_biquad c);
/// Zeroes subnormal state.
void eqc_biquad_flush(eqc_biquad_state *state);
/// False when the range is empty or not finite once clamped.
bool eqc_clamp_solo(double low, double high, double sampleRate, double *clampedLow, double *clampedHigh);
eqc_compressor_settings eqc_compressor_params(eqc_compressor compressor);
eqc_dynamics eqc_dynamics_design(eqc_compressor compressor, eqc_colour colour, double amount, double sampleRate);
/// The static curve: the gain change in dB, 0 or below, for a detector level in dB.
float eqc_reduction(float level, float threshold, float knee, float slope);
/// One frame of the compressor and colour across `channelCount` channels, in place. `detector` and
/// `dc` hold 2 × channelCount entries. Returns the frame's largest magnitude.
float eqc_dynamics_frame(const eqc_dynamics *c, const eqc_channel *_Nonnull channels, int32_t frame, int32_t channelCount,
                         eqc_dynamics_state *state, eqc_biquad_state *detector, float *dc);

// Engine.

size_t eqc_engine_size(void);
/// 48 kHz, 2 channels, passing sound through until the first `eqc_update`. The meter's band
/// centres are copied; at most `EQC_MAX_METER_BANDS`.
void eqc_engine_init(eqc_engine *engine, const double *meterFrequencies, int32_t meterBands);
/// Channels are clamped to 1...EQC_MAX_CHANNELS. Resets the meter and, if `eqc_update` ran before,
/// prepares its settings again for the new rate.
void eqc_configure(eqc_engine *engine, double sampleRate, int32_t channels);
/// Publisher thread. Computes every coefficient at the configured rate and hands them to the render
/// thread; a band whose filter is unstable there runs as a wire. Writes the indices of those bands
/// into `unstable` (room for EQC_MAX_BANDS) when given, and returns their count. A new program
/// starts its filters from silence.
int32_t eqc_update(eqc_engine *engine, const eqc_settings *settings, int32_t *_Nullable unstable);
/// Render thread. Non-interleaved channels, in place. Channels past EQC_MAX_CHANNELS are left as
/// they are. Order: preamp, EQ bands and solo, output gain, compressor, colour, limiter, meter.
/// A NaN or infinite input sample plays as 0. History that stops being finite is cleared at the end
/// of the call, which then outputs silence, so one bad block never silences the ones after it.
void eqc_process(eqc_engine *engine, const eqc_channel *_Nonnull channels, int32_t channelCount, int32_t frames);
/// Render thread. Clears filter, limiter and meter history before a long silence; a following
/// makeup keeps what it learned.
void eqc_reset_render_state(eqc_engine *engine);
void eqc_set_metering(eqc_engine *engine, bool enabled);
/// Whether the last `eqc_process` call limited.
bool eqc_limiting(const eqc_engine *engine);
/// The compressor's gain change in dB before makeup, 0 or below.
float eqc_compressor_reduction_db(const eqc_engine *engine);
eqc_meter *eqc_engine_meter(eqc_engine *engine);
/// Copies the render thread's history into `out`, returning how many values it wrote (at most
/// `capacity`). For tests; only while nothing renders.
int32_t eqc_engine_render_state(const eqc_engine *engine, float *out, int32_t capacity);

// Meter: per-band peak envelopes of the mono sum 0.5 × (channel 0 + channel 1), before and after.

size_t eqc_meter_size(void);
void eqc_meter_init(eqc_meter *meter, const double *frequencies, int32_t bands);
void eqc_meter_configure(eqc_meter *meter, double sampleRate);
void eqc_meter_reset(eqc_meter *meter);
void eqc_meter_feed(eqc_meter *meter, const eqc_channel *_Nonnull input, int32_t inputChannels,
                    const eqc_channel *_Nonnull output, int32_t outputChannels, int32_t frames);
int32_t eqc_meter_band_count(const eqc_meter *meter);
/// Any thread, racing the render thread: each value is old or new, never torn. `input` and
/// `output` hold `eqc_meter_band_count` values, in dB, floored at EQC_METER_FLOOR_DB.
void eqc_meter_read(const eqc_meter *meter, double *input, double *output, double *peak);
int32_t eqc_meter_render_state(const eqc_meter *meter, float *out, int32_t capacity);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
