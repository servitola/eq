#include "EQResampler.h"

#include <math.h>

// Positions are 32.32 fixed point in input frames, so a block's last position is known exactly
// before the block runs and `needed` never disagrees with `produce` by a rounding.
#define FRACTION_BITS 32
#define PHASE_BITS 10
#define PHASES (1 << PHASE_BITS)
#define BLEND_BITS (FRACTION_BITS - PHASE_BITS)
// 32 taps a side at 1:1: a Kaiser window with this beta keeps the stopband below -90 dB for a
// transition from 0.4547 to 0.5453 of the lower rate, so 20 kHz passes at 44.1 kHz and everything
// that folds back lands above it.
#define HALF_TAPS 32
#define KAISER_BETA 9.0
#define PI 3.14159265358979323846264338327950288
#define ONE ((int64_t)1 << FRACTION_BITS)

struct eqc_resampler {
    int32_t channels, taps, half, capacity, maxOutput;
    double nominal;
    int64_t step, position, base;
    int32_t fill;
    float *table, *coefficients, *history;
};

static size_t align16(size_t bytes) { return (bytes + 15) & ~(size_t)15; }

typedef struct {
    int32_t half, taps, capacity;
    size_t header, table, coefficients, history;
} layout;

static int layout_for(double inputRate, double outputRate, int32_t channels, int32_t maxOutputFrames, layout *l) {
    if (!(inputRate > 0) || !(outputRate > 0) || channels < 1 || channels > EQC_RESAMPLER_MAX_CHANNELS || maxOutputFrames < 1) return 0;
    double ratio = inputRate / outputRate;
    if (ratio > EQC_RESAMPLER_MAX_RATIO || ratio < 1 / EQC_RESAMPLER_MAX_RATIO) return 0;
    // Decimating stretches the kernel so its transition stays the same width at the output rate.
    int32_t pairs = (int32_t)ceil(HALF_TAPS / 2.0 * (ratio > 1 ? ratio : 1));
    l->half = 2 * pairs;
    l->taps = 2 * l->half;
    int32_t maxInput = (int32_t)ceil(maxOutputFrames * ratio * (1 + EQC_RESAMPLER_MAX_CORRECTION)) + 2;
    l->capacity = l->taps + maxInput + 2;
    l->header = align16(sizeof(eqc_resampler));
    l->table = align16(sizeof(float) * (size_t)(PHASES + 1) * (size_t)l->taps);
    l->coefficients = align16(sizeof(float) * (size_t)l->taps);
    l->history = align16(sizeof(float) * (size_t)l->capacity * (size_t)channels);
    return 1;
}

size_t eqc_resampler_size(double inputRate, double outputRate, int32_t channels, int32_t maxOutputFrames) {
    layout l;
    if (!layout_for(inputRate, outputRate, channels, maxOutputFrames, &l)) return 0;
    return l.header + l.table + l.coefficients + l.history;
}

static double bessel_i0(double x) {
    double sum = 1, term = 1, half = x / 2;
    for (int k = 1; k < 200; k++) {
        term *= (half / k) * (half / k);
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

static double kernel(double t, double cutoff, double half) {
    double u = t / half;
    if (u <= -1 || u >= 1) return 0;
    double x = 2 * cutoff * t;
    double sinc = fabs(x) < 1e-12 ? 1 : sin(PI * x) / (PI * x);
    return 2 * cutoff * sinc * bessel_i0(KAISER_BETA * sqrt(1 - u * u)) / bessel_i0(KAISER_BETA);
}

void eqc_resampler_init(eqc_resampler *r, double inputRate, double outputRate, int32_t channels, int32_t maxOutputFrames) {
    layout l;
    if (!layout_for(inputRate, outputRate, channels, maxOutputFrames, &l)) return;
    char *base = (char *)r;
    r->channels = channels;
    r->taps = l.taps;
    r->half = l.half;
    r->capacity = l.capacity;
    r->maxOutput = maxOutputFrames;
    r->nominal = inputRate / outputRate;
    r->table = (float *)(base + l.header);
    r->coefficients = (float *)(base + l.header + l.table);
    r->history = (float *)(base + l.header + l.table + l.coefficients);
    double cutoff = 0.5 * (outputRate < inputRate ? outputRate / inputRate : 1);
    // Row p holds the taps for an output p/PHASES of a frame past an input frame; each row sums to
    // exactly 1, so no phase gains or loses level at DC.
    for (int32_t p = 0; p <= PHASES; p++) {
        float *row = r->table + (size_t)p * (size_t)r->taps;
        double mu = (double)p / PHASES, sum = 0;
        for (int32_t k = 0; k < r->taps; k++) sum += kernel(k - r->half + 1 - mu, cutoff, r->half);
        for (int32_t k = 0; k < r->taps; k++) row[k] = (float)(kernel(k - r->half + 1 - mu, cutoff, r->half) / sum);
    }
    eqc_resampler_set_correction(r, 0);
    eqc_resampler_reset(r);
}

// The render thread's copying and clearing loops: left to the optimiser they become calls to libc.
__attribute__((no_builtin, noinline)) static void clear(float *values, int32_t count) {
    for (int32_t i = 0; i < count; i++) values[i] = 0;
}

__attribute__((no_builtin, noinline)) static void move_down(float *values, int32_t from, int32_t count) {
    for (int32_t i = 0; i < count; i++) values[i] = values[from + i];
}

void eqc_resampler_reset(eqc_resampler *r) {
    for (int32_t c = 0; c < r->channels; c++) clear(r->history + (size_t)c * (size_t)r->capacity, r->capacity);
    // Half a kernel of silence before input frame 0, which the first output frame sits on.
    r->fill = r->half - 1;
    r->position = (int64_t)(r->half - 1) * ONE;
    r->base = -(int64_t)(r->half - 1);
}

void eqc_resampler_set_correction(eqc_resampler *r, double correction) {
    if (!(correction >= -EQC_RESAMPLER_MAX_CORRECTION)) correction = -EQC_RESAMPLER_MAX_CORRECTION;
    if (correction > EQC_RESAMPLER_MAX_CORRECTION) correction = EQC_RESAMPLER_MAX_CORRECTION;
    r->step = (int64_t)(r->nominal * (1 + correction) * (double)ONE + 0.5);
}

double eqc_resampler_step(const eqc_resampler *r) { return (double)r->step / (double)ONE; }

static int32_t required_fill(const eqc_resampler *r, int32_t outputFrames) {
    int64_t last = r->position + (int64_t)(outputFrames - 1) * r->step;
    return (int32_t)(last >> FRACTION_BITS) + r->half + 1;
}

int32_t eqc_resampler_needed(const eqc_resampler *r, int32_t outputFrames) {
    if (outputFrames < 1) return 0;
    if (outputFrames > r->maxOutput) outputFrames = r->maxOutput;
    int32_t needed = required_fill(r, outputFrames) - r->fill;
    return needed > 0 ? needed : 0;
}

float *eqc_resampler_input(eqc_resampler *r, int32_t channel) {
    if (channel < 0) channel = 0;
    if (channel >= r->channels) channel = r->channels - 1;
    return r->history + (size_t)channel * (size_t)r->capacity + r->fill;
}

void eqc_resampler_produce(eqc_resampler *r, int32_t inputFrames, float *const *output, int32_t outputFrames) {
    if (outputFrames > r->maxOutput) outputFrames = r->maxOutput;
    if (outputFrames < 1) return;
    int32_t required = required_fill(r, outputFrames);
    if (inputFrames < 0) inputFrames = 0;
    if (r->fill + inputFrames > required) inputFrames = required - r->fill;
    r->fill += inputFrames;
    if (r->fill < required) {
        for (int32_t c = 0; c < r->channels; c++) clear(r->history + (size_t)c * (size_t)r->capacity + r->fill, required - r->fill);
        r->fill = required;
    }

    const int32_t taps = r->taps;
    float *coefficients = r->coefficients;
    for (int32_t i = 0; i < outputFrames; i++) {
        int64_t n = r->position >> FRACTION_BITS;
        uint32_t fraction = (uint32_t)(r->position & (ONE - 1));
        const float *row = r->table + (size_t)(fraction >> BLEND_BITS) * (size_t)taps;
        const float *next = row + taps;
        float blend = (float)(fraction & ((1u << BLEND_BITS) - 1)) * (1.0f / (float)(1u << BLEND_BITS));
        for (int32_t k = 0; k < taps; k++) coefficients[k] = row[k] + blend * (next[k] - row[k]);
        size_t first = (size_t)(n - r->half + 1);
        for (int32_t c = 0; c < r->channels; c++) {
            const float *x = r->history + (size_t)c * (size_t)r->capacity + first;
            float a0 = 0, a1 = 0, a2 = 0, a3 = 0;
            for (int32_t k = 0; k < taps; k += 4) {
                a0 += coefficients[k] * x[k];
                a1 += coefficients[k + 1] * x[k + 1];
                a2 += coefficients[k + 2] * x[k + 2];
                a3 += coefficients[k + 3] * x[k + 3];
            }
            output[c][i] = (a0 + a1) + (a2 + a3);
        }
        r->position += r->step;
    }

    int32_t shift = (int32_t)(r->position >> FRACTION_BITS) - r->half + 1;
    if (shift > 0) {
        for (int32_t c = 0; c < r->channels; c++) move_down(r->history + (size_t)c * (size_t)r->capacity, shift, r->fill - shift);
        r->fill -= shift;
        r->position -= (int64_t)shift * ONE;
        r->base += shift;
    }
}

double eqc_resampler_position(const eqc_resampler *r) {
    return (double)r->base + (double)r->position / (double)ONE;
}

int32_t eqc_resampler_latency(const eqc_resampler *r) { return r->half; }
int32_t eqc_resampler_taps(const eqc_resampler *r) { return r->taps; }
