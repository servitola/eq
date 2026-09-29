#ifndef EQ_RESAMPLER_H
#define EQ_RESAMPLER_H

// An asynchronous sample-rate converter for a route: a windowed-sinc polyphase filter whose ratio
// may move by up to EQC_RESAMPLER_MAX_CORRECTION between calls, so a drift servo can steer it. The
// caller owns the memory (`eqc_resampler_size`, 16-byte aligned). Everything but `init` is for the
// render thread and calls nothing, not even libm.
//
// Pull model: ask how many input frames the next `outputFrames` need, write exactly that many into
// the `eqc_resampler_input` buffers, then `eqc_resampler_produce`.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define EQC_RESAMPLER_MAX_CHANNELS 16
#define EQC_RESAMPLER_MAX_CORRECTION 1e-3
/// Rates further apart than this are refused by `eqc_resampler_size`.
#define EQC_RESAMPLER_MAX_RATIO 8.0

typedef struct eqc_resampler eqc_resampler;

/// 0 when the rates, channels or frames are out of range.
size_t eqc_resampler_size(double inputRate, double outputRate, int32_t channels, int32_t maxOutputFrames);
/// Designs the filter; not realtime. Arguments as given to `eqc_resampler_size`.
void eqc_resampler_init(eqc_resampler *resampler, double inputRate, double outputRate, int32_t channels, int32_t maxOutputFrames);
/// Clears the history; the next output frame is input frame 0.
void eqc_resampler_reset(eqc_resampler *resampler);
/// Input frames per output frame become inputRate / outputRate × (1 + correction), clamped.
void eqc_resampler_set_correction(eqc_resampler *resampler, double correction);
/// Input frames per output frame, as the fixed-point step really advances.
double eqc_resampler_step(const eqc_resampler *resampler);
/// Input frames the next `outputFrames` (at most the maximum given to init) need.
int32_t eqc_resampler_needed(const eqc_resampler *resampler, int32_t outputFrames);
/// Where the next input frames of `channel` go; room for `eqc_resampler_needed` frames.
float *eqc_resampler_input(eqc_resampler *resampler, int32_t channel);
/// Takes the `inputFrames` written (short of what was needed, the rest reads as silence) and writes
/// `outputFrames` into one buffer per channel.
void eqc_resampler_produce(eqc_resampler *resampler, int32_t inputFrames, float *const _Nonnull *_Nonnull output,
                           int32_t outputFrames);
/// Input frames since the last reset at which the next output frame sits: that frame is the
/// band-limited input at this fractional position, with no phase shift.
double eqc_resampler_position(const eqc_resampler *resampler);
/// Input frames the filter reads past the position: what it adds to a path's delay.
int32_t eqc_resampler_latency(const eqc_resampler *resampler);
int32_t eqc_resampler_taps(const eqc_resampler *resampler);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
