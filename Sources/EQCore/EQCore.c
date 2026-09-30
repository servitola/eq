// The biquad design and the render loop began as zollans/OnlyEQ @ 6569655 (Unlicense).
#include "EQCore.h"

#include <float.h>
#include <math.h>

// Contracting a * b + c into one fused operation would change results in their last bits, and
// differently under other build flags; the daemon and the plug-in must agree to the bit.
#pragma STDC FP_CONTRACT OFF
// The render thread's clearing loops: left to the optimiser, each would become a call to libc's
// bzero, and the render thread calls nothing outside libm. Kept out of line, since inlining one
// would hand its loop back to the optimiser.
#define CLEARS __attribute__((no_builtin, noinline))

#define EQC_MAX_SECTIONS (EQC_MAX_BANDS + 4)
#define PI 3.14159265358979323846264338327950288

// Swift's min and max, NaN handling included: max(x, y) is `y >= x ? y : x`, min is `y < x ? y : x`.
static inline double dmax(double x, double y) { return y >= x ? y : x; }
static inline double dmin(double x, double y) { return y < x ? y : x; }
static inline float fmaxs(float x, float y) { return y >= x ? y : x; }
static inline float fmins(float x, float y) { return y < x ? y : x; }

static const eqc_biquad identity = {1, 0, 0, 0, 0};

CLEARS static void clear(float *values, int32_t count) {
    for (int32_t i = 0; i < count; i++) values[i] = 0;
}

// MARK: - Biquads

eqc_biquad eqc_design(eqc_filter_type type, double frequency, double gainDB, double rawQ, double sampleRate) {
    double fc = dmin(dmax(frequency, 1), sampleRate * 0.499);
    double q = dmax(rawQ, 0.025);
    double a = pow(10.0, gainDB / 40.0);
    double w0 = 2.0 * PI * fc / sampleRate;
    double cosw = cos(w0), sinw = sin(w0);
    double alpha = sinw / (2.0 * q);

    double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
    switch (type) {
    case EQC_PEAK:
        b0 = 1 + alpha * a;
        b1 = -2 * cosw;
        b2 = 1 - alpha * a;
        a0 = 1 + alpha / a;
        a1 = -2 * cosw;
        a2 = 1 - alpha / a;
        break;
    case EQC_LOW_SHELF: {
        double s = 2 * sqrt(a) * alpha;
        b0 = a * ((a + 1) - (a - 1) * cosw + s);
        b1 = 2 * a * ((a - 1) - (a + 1) * cosw);
        b2 = a * ((a + 1) - (a - 1) * cosw - s);
        a0 = (a + 1) + (a - 1) * cosw + s;
        a1 = -2 * ((a - 1) + (a + 1) * cosw);
        a2 = (a + 1) + (a - 1) * cosw - s;
        break;
    }
    case EQC_HIGH_SHELF: {
        double s = 2 * sqrt(a) * alpha;
        b0 = a * ((a + 1) + (a - 1) * cosw + s);
        b1 = -2 * a * ((a - 1) + (a + 1) * cosw);
        b2 = a * ((a + 1) + (a - 1) * cosw - s);
        a0 = (a + 1) - (a - 1) * cosw + s;
        a1 = 2 * ((a - 1) - (a + 1) * cosw);
        a2 = (a + 1) - (a - 1) * cosw - s;
        break;
    }
    case EQC_LOW_PASS:
        b0 = (1 - cosw) / 2;
        b1 = 1 - cosw;
        b2 = (1 - cosw) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cosw;
        a2 = 1 - alpha;
        break;
    case EQC_HIGH_PASS:
        b0 = (1 + cosw) / 2;
        b1 = -(1 + cosw);
        b2 = (1 + cosw) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cosw;
        a2 = 1 - alpha;
        break;
    case EQC_NOTCH:
        b0 = 1;
        b1 = -2 * cosw;
        b2 = 1;
        a0 = 1 + alpha;
        a1 = -2 * cosw;
        a2 = 1 - alpha;
        break;
    case EQC_BAND_PASS:
        b0 = alpha;
        b1 = 0;
        b2 = -alpha;
        a0 = 1 + alpha;
        a1 = -2 * cosw;
        a2 = 1 - alpha;
        break;
    }
    return (eqc_biquad){(float)(b0 / a0), (float)(b1 / a0), (float)(b2 / a0), (float)(a1 / a0), (float)(a2 / a0)};
}

// Jury's triangle for a normalised second-order denominator.
bool eqc_biquad_is_stable(eqc_biquad c) { return fabsf(c.a2) < 1 && fabsf(c.a1) < 1 + c.a2; }

static inline float biquad(eqc_biquad_state *s, float x, const eqc_biquad *c) {
    float y = c->b0 * x + s->z1;
    s->z1 = c->b1 * x - c->a1 * y + s->z2;
    s->z2 = c->b2 * x - c->a2 * y;
    return y;
}

// A decaying tail parks the state in subnormals: flush-to-zero is off on these threads, and
// subnormal arithmetic can cost far more than normal arithmetic.
static inline void flush(eqc_biquad_state *s) {
    if (fabsf(s->z1) < FLT_MIN) s->z1 = 0;
    if (fabsf(s->z2) < FLT_MIN) s->z2 = 0;
}

float eqc_biquad_process(eqc_biquad_state *state, float x, eqc_biquad c) { return biquad(state, x, &c); }
void eqc_biquad_flush(eqc_biquad_state *state) { flush(state); }

bool eqc_clamp_solo(double low, double high, double sampleRate, double *clampedLow, double *clampedHigh) {
    if (!isfinite(low) || !isfinite(high) || !(sampleRate > 0)) return false;
    double l = dmax(low, 20), h = dmin(high, 0.45 * sampleRate);
    if (!(l < h)) return false;
    *clampedLow = l;
    *clampedHigh = h;
    return true;
}

// MARK: - Compressor and colour

// Gentle's 50 ms window keeps a kick from pumping the gain much: 2.3 dB peak to peak on a 55 Hz kick
// alone against 2.9 dB at 2.5 ms. Night keeps 2.5 ms so its 5 ms attack still catches an explosion's
// onset: at 25 ms the explosions' peaks come out 3 dB higher. Night's fixed makeup restores film
// dialogue at −24 dB; gentle's follows the reduction so music stays as loud.
eqc_compressor_settings eqc_compressor_params(eqc_compressor compressor) {
    switch (compressor) {
    case EQC_COMPRESSOR_NIGHT: return (eqc_compressor_settings){4, -30, 10, 0.005, 0.400, 0.0025, -24};
    case EQC_COMPRESSOR_GENTLE: return (eqc_compressor_settings){2, -18, 6, 0.030, 0.250, 0.050, NAN};
    default: return (eqc_compressor_settings){1, 0, 0, 0, 0, 0, NAN};
    }
}

// A following makeup gives back the reduction averaged over this long: slow enough to leave a
// phrase's dynamics compressed, fast enough that a song's loud and quiet parts both end up as loud
// as they went in.
#define FOLLOW_TIME 3.0
// Drive at amount 1: tanh(2x)/2 takes a −12 dBFS sine down 0.7 dB with 2 % third harmonic.
#define MAX_DRIVE 2.0
// Tube's bias as a fraction of the input: how much second harmonic it makes against third.
#define TUBE_BIAS 0.25
#define DC_CORNER 5.0
#define GLIDE_TIME 0.010
// A drive this close to where it glides to is there: at 1e-4 the curve is x within 1e-9.
#define DRIVE_SNAP 1e-4f
// The tube's DC blocker keeps running after its drive reaches 0 until its tail is this small.
#define DC_SNAP 1e-5f

static inline float reduction(float level, float threshold, float knee, float slope) {
    float over = level - threshold;
    if (2 * over <= -knee) return 0;
    if (2 * over < knee) {
        float x = over + knee / 2;
        return slope * x * x / (2 * knee);
    }
    return slope * over;
}

float eqc_reduction(float level, float threshold, float knee, float slope) {
    return reduction(level, threshold, knee, slope);
}

static eqc_dynamics dynamics_off(void) {
    eqc_dynamics c = {0};
    c.detectorShelf = identity;
    c.detectorHighPass = identity;
    c.biasNormal = 1;
    return c;
}

static float pole(double seconds, double sampleRate) { return (float)exp(-1 / (seconds * sampleRate)); }

// The glide, and the tube's DC blocker for the tail of a switch-off, are there even with both
// stages off, so a switch-off still has them.
eqc_dynamics eqc_dynamics_design(eqc_compressor compressor, eqc_colour colour, double amount, double sampleRate) {
    eqc_dynamics c = dynamics_off();
    if (!(sampleRate > 0)) return c;
    c.glide = pole(GLIDE_TIME, sampleRate);
    c.dcPole = pole(1 / (2 * PI * DC_CORNER), sampleRate);
    if (compressor == EQC_COMPRESSOR_GENTLE || compressor == EQC_COMPRESSOR_NIGHT) {
        eqc_compressor_settings s = eqc_compressor_params(compressor);
        c.compressor = true;
        c.detectorShelf = eqc_design(EQC_HIGH_SHELF, EQC_K_SHELF_FREQUENCY, EQC_K_SHELF_GAIN_DB, EQC_K_SHELF_Q, sampleRate);
        c.detectorHighPass = eqc_design(EQC_HIGH_PASS, EQC_K_HIGH_PASS_FREQUENCY, 0, EQC_K_HIGH_PASS_Q, sampleRate);
        c.detectorSmoothing = pole(s.window, sampleRate);
        c.attack = pole(s.attack, sampleRate);
        c.release = pole(s.release, sampleRate);
        c.threshold = (float)s.threshold;
        c.knee = (float)s.knee;
        c.slope = (float)(1 / s.ratio - 1);
        if (!isnan(s.reference)) {
            c.makeupDB = -reduction((float)s.reference, c.threshold, c.knee, c.slope);
        } else {
            c.makeupFollow = pole(FOLLOW_TIME, sampleRate);
            c.followGateDB = c.threshold - EQC_FOLLOW_GATE_BELOW_THRESHOLD;
        }
        // Never ahead of the reduction: switched on, or after a reset in silence, the reduction
        // starts from 0, and makeup arriving faster than the attack would swell the level first.
        c.makeupGlide = pole(dmax(s.attack, GLIDE_TIME), sampleRate);
    }
    if ((colour == EQC_COLOUR_TAPE || colour == EQC_COLOUR_TUBE) && amount > 0) {
        double drive = dmin(dmax(amount, 0), 1) * MAX_DRIVE;
        c.colour = colour;
        c.drive = (float)drive;
        c.inverseDrive = (float)(1 / drive);
        if (colour == EQC_COLOUR_TUBE) {
            double t = tanh(drive * TUBE_BIAS);
            c.bias = (float)(drive * TUBE_BIAS);
            // The render thread's own float tanh, so silence in is exactly silence out.
            c.biasOffset = tanhf(c.bias);
            // The slope at rest, so a quiet signal comes out as loud as it went in.
            c.biasNormal = (float)(1 / (drive * (1 - t * t)));
        }
    }
    return c;
}

static inline bool settled(const float *dc, int32_t count) {
    for (int32_t i = 0; i < count; i++)
        if (fabsf(dc[i]) >= DC_SNAP) return false;
    return true;
}

// One gain for all channels, set by the loudest, so the centre of 5.1 alone reads as loud as the
// same signal on both sides of stereo; then the colour.
__attribute__((always_inline)) static inline float dynamics_frame(const eqc_dynamics *c, const eqc_channel *channels, int32_t frame, int32_t channelCount,
                                   eqc_dynamics_state *state, eqc_biquad_state *detector, float *dc) {
    float gain = 1;
    if (c->compressor) {
        float power = 0;
        for (int32_t ch = 0; ch < channelCount; ch++) {
            float filtered = biquad(&detector[2 * ch + 1], biquad(&detector[2 * ch], channels[ch][frame], &c->detectorShelf),
                                    &c->detectorHighPass);
            power = fmaxs(power, filtered * filtered);
        }
        state->meanSquare = c->detectorSmoothing * state->meanSquare + (1 - c->detectorSmoothing) * power;
        float level = 10 * log10f(state->meanSquare + 1e-12f);
        float target = reduction(level, c->threshold, c->knee, c->slope);
        float p = target < state->reductionDB ? c->attack : c->release;
        state->reductionDB = p * state->reductionDB + (1 - p) * target;
        float makeupTarget = c->makeupDB;
        if (c->makeupFollow > 0) {
            if (level > c->followGateDB)
                state->averageReductionDB = c->makeupFollow * state->averageReductionDB + (1 - c->makeupFollow) * state->reductionDB;
            makeupTarget = fmins(-state->averageReductionDB, EQC_MAX_MAKEUP_DB);
        }
        state->makeupDB = c->makeupGlide * state->makeupDB + (1 - c->makeupGlide) * makeupTarget;
        gain = exp2f((state->reductionDB + state->makeupDB) * 0.1660964f);
    } else if (state->reductionDB != 0 || state->makeupDB != 0) {
        state->reductionDB *= c->glide;
        state->makeupDB *= c->glide;
        gain = exp2f((state->reductionDB + state->makeupDB) * 0.1660964f);
    }

    float targetDrive = state->colour == c->colour ? c->drive : 0;
    if (state->drive != targetDrive) {
        state->drive = c->glide * state->drive + (1 - c->glide) * targetDrive;
        if (fabsf(state->drive - targetDrive) < DRIVE_SNAP) state->drive = targetDrive;
    }
    if (state->drive == 0 && state->colour != c->colour && (state->colour != EQC_COLOUR_TUBE || settled(dc, 2 * channelCount))) {
        state->colour = c->colour;
        clear(dc, 2 * channelCount);
    }
    float d = state->drive;
    float inverse = c->inverseDrive, b = c->bias, offset = c->biasOffset, normal = c->biasNormal;
    if (d > 0 && (d != c->drive || state->colour != c->colour)) {
        inverse = 1 / d;
        b = d * (float)TUBE_BIAS;
        offset = tanhf(b);
        normal = inverse / (1 - offset * offset);
    }

    float peak = 0;
    for (int32_t ch = 0; ch < channelCount; ch++) {
        float sample = channels[ch][frame] * gain;
        switch (state->colour) {
        case EQC_COLOUR_TAPE:
            if (d > 0) sample = tanhf(d * sample) * inverse;
            break;
        case EQC_COLOUR_TUBE: {
            // Blocking only what the curve adds keeps the dry signal whole, so at 0 drive the stage
            // is exactly a wire and a switch has nothing to jump over.
            float added = d > 0 ? (tanhf(d * sample + b) - offset) * normal - sample : 0;
            float blocked = added - dc[2 * ch] + c->dcPole * dc[2 * ch + 1];
            dc[2 * ch] = added;
            dc[2 * ch + 1] = blocked;
            sample += blocked;
            break;
        }
        default:
            break;
        }
        channels[ch][frame] = sample;
        peak = fmaxs(peak, fabsf(sample));
    }
    return peak;
}

float eqc_dynamics_frame(const eqc_dynamics *c, const eqc_channel *channels, int32_t frame, int32_t channelCount,
                         eqc_dynamics_state *state, eqc_biquad_state *detector, float *dc) {
    return dynamics_frame(c, channels, frame, channelCount, state, detector, dc);
}

static inline bool dynamics_active(const eqc_dynamics *c) { return c->compressor || c->colour != EQC_COLOUR_OFF; }

static inline bool dynamics_idle(const eqc_dynamics_state *s) {
    return s->reductionDB == 0 && s->makeupDB == 0 && s->colour == EQC_COLOUR_OFF;
}

// A release creeps towards 0 dB geometrically and would take the better part of a minute to get
// there; a thousandth of a dB is far below hearing, so it ends there. Makeup only ends on the way
// out: on the way in a 1-frame callback at 192 kHz moves it less than that.
static inline void flush_tails(eqc_dynamics_state *s, bool compressing) {
    if (s->meanSquare < FLT_MIN) s->meanSquare = 0;
    if (fabsf(s->reductionDB) < 1e-3f) s->reductionDB = 0;
    if (fabsf(s->averageReductionDB) < 1e-3f) s->averageReductionDB = 0;
    if (!compressing && fabsf(s->makeupDB) < 1e-3f) s->makeupDB = 0;
}

// MARK: - Meter

#define METER_FLOOR_LINEAR 1e-3f

struct eqc_meter {
    int32_t bandCount;
    double frequencies[EQC_MAX_METER_BANDS];
    eqc_biquad coefficients[EQC_MAX_METER_BANDS];
    // [input bands | output bands]
    eqc_biquad_state states[2 * EQC_MAX_METER_BANDS];
    float envelopes[2 * EQC_MAX_METER_BANDS];
    float peakEnvelope, attack, release;
    // Readers copy these while the render thread writes them: an aligned 8-byte store is atomic
    // on arm64, so a reader sees an old or a new value per band, never a torn one.
    double levels[2 * EQC_MAX_METER_BANDS];
    double peakLevel;
    // The output's third octaves; bands from `spectrumBands` up lie past what the rate can carry.
    int32_t spectrumBands;
    eqc_biquad spectrumCoefficients[EQC_SPECTRUM_BANDS];
    eqc_biquad_state spectrumStates[EQC_SPECTRUM_BANDS];
    float spectrumEnvelopes[EQC_SPECTRUM_BANDS];
    double spectrumLevels[EQC_SPECTRUM_BANDS];
};

static inline void store_level(double *cell, double value) { __atomic_store(cell, &value, __ATOMIC_RELAXED); }

static inline double load_level(const double *cell) {
    double value;
    __atomic_load(cell, &value, __ATOMIC_RELAXED);
    return value;
}

size_t eqc_meter_size(void) { return sizeof(eqc_meter); }

// ISO 266's preferred numbers are the rounded values of these, the base-ten third octaves.
double eqc_spectrum_frequency(int32_t band) { return 1000 * pow(10, (band - 17) / 10.0); }

CLEARS static void spectrum_reset(eqc_meter *m) {
    for (int32_t i = 0; i < EQC_SPECTRUM_BANDS; i++) {
        m->spectrumStates[i] = (eqc_biquad_state){0, 0};
        m->spectrumEnvelopes[i] = 0;
        store_level(&m->spectrumLevels[i], EQC_METER_FLOOR_DB);
    }
}

CLEARS void eqc_meter_reset(eqc_meter *m) {
    spectrum_reset(m);
    for (int32_t i = 0; i < 2 * m->bandCount; i++) {
        m->states[i] = (eqc_biquad_state){0, 0};
        m->envelopes[i] = 0;
        store_level(&m->levels[i], EQC_METER_FLOOR_DB);
    }
    m->peakEnvelope = 0;
    store_level(&m->peakLevel, EQC_METER_FLOOR_DB);
}

void eqc_meter_configure(eqc_meter *m, double sampleRate) {
    for (int32_t band = 0; band < m->bandCount; band++)
        m->coefficients[band] = eqc_design(EQC_BAND_PASS, m->frequencies[band], 0, 1.41, sampleRate);
    // A third octave's Q: its edges, a sixth of an octave either side, are where it is 3 dB down,
    // so neighbouring bands meet there and a sine anywhere reads within 3 dB of its level.
    double ratio = pow(10, 0.1), q = sqrt(ratio) / (ratio - 1);
    m->spectrumBands = 0;
    while (m->spectrumBands < EQC_SPECTRUM_BANDS && eqc_spectrum_frequency(m->spectrumBands) < 0.49 * sampleRate) {
        m->spectrumCoefficients[m->spectrumBands] = eqc_design(EQC_BAND_PASS, eqc_spectrum_frequency(m->spectrumBands), 0, q, sampleRate);
        m->spectrumBands++;
    }
    m->attack = (float)exp(-1 / (0.010 * sampleRate));
    m->release = (float)exp(-1 / (0.300 * sampleRate));
    eqc_meter_reset(m);
}

void eqc_meter_init(eqc_meter *m, const double *frequencies, int32_t bands) {
    *m = (eqc_meter){0};
    m->bandCount = bands < 0 ? 0 : bands > EQC_MAX_METER_BANDS ? EQC_MAX_METER_BANDS : bands;
    for (int32_t band = 0; band < m->bandCount; band++) m->frequencies[band] = frequencies[band];
    eqc_meter_configure(m, 48000);
}

static inline float follow(float env, float x, float attack, float release) {
    return x > env ? attack * env + (1 - attack) * x : release * env + (1 - release) * x;
}

static inline double decibels(float envelope) {
    return envelope > METER_FLOOR_LINEAR ? 20 * log10((double)envelope) : EQC_METER_FLOOR_DB;
}

// Restrict parameters, not locals: only they tell the optimiser the bands' state, envelopes and
// coefficients never overlap, which lets it run four bands at once.
static inline void meter_bands(float mono, eqc_biquad_state *restrict states, float *restrict envelopes,
                               const eqc_biquad *restrict coefficients, int32_t bands, float attack, float release) {
    for (int32_t band = 0; band < bands; band++) {
        float y = fabsf(biquad(&states[band], mono, &coefficients[band]));
        envelopes[band] = follow(envelopes[band], y, attack, release);
    }
}

// `first` is NULL for no channels; `second` is `first` again for one.
static void meter_run(eqc_meter *m, const float *first, const float *second, int32_t offset, int32_t frames, bool trackPeak) {
    if (!first) return;
    float attack = m->attack, release = m->release, peak = m->peakEnvelope;
    for (int32_t frame = 0; frame < frames; frame++) {
        float mono = 0.5f * (first[frame] + second[frame]);
        if (trackPeak) peak = follow(peak, fmaxs(fabsf(first[frame]), fabsf(second[frame])), attack, release);
        meter_bands(mono, m->states + offset, m->envelopes + offset, m->coefficients, m->bandCount, attack, release);
    }
    m->peakEnvelope = peak;
}

static void meter_feed(eqc_meter *m, const float *input, const float *secondInput,
                       const float *output, const float *secondOutput, int32_t frames) {
    int32_t bands = m->bandCount;
    meter_run(m, input, secondInput, 0, frames, false);
    meter_run(m, output, secondOutput, bands, frames, true);
    for (int32_t i = 0; i < 2 * bands; i++) store_level(&m->levels[i], decibels(m->envelopes[i]));
    store_level(&m->peakLevel, decibels(m->peakEnvelope));
    for (int32_t i = 0; i < 2 * bands; i++) {
        if (!isfinite(m->envelopes[i]) || !isfinite(m->states[i].z1) || !isfinite(m->states[i].z2)) {
            m->envelopes[i] = 0;
            m->states[i] = (eqc_biquad_state){0, 0};
            store_level(&m->levels[i], EQC_METER_FLOOR_DB);
        }
    }
    if (!isfinite(m->peakEnvelope)) {
        m->peakEnvelope = 0;
        store_level(&m->peakLevel, EQC_METER_FLOOR_DB);
    }
    for (int32_t i = 0; i < 2 * bands; i++) {
        flush(&m->states[i]);
        if (m->envelopes[i] < FLT_MIN) m->envelopes[i] = 0;
    }
    if (m->peakEnvelope < FLT_MIN) m->peakEnvelope = 0;
}

void eqc_meter_feed(eqc_meter *m, const eqc_channel *input, int32_t inputChannels,
                    const eqc_channel *output, int32_t outputChannels, int32_t frames) {
    const float *in = inputChannels > 0 ? input[0] : NULL, *out = outputChannels > 0 ? output[0] : NULL;
    meter_feed(m, in, inputChannels > 1 ? input[1] : in, out, outputChannels > 1 ? output[1] : out, frames);
}

static void spectrum_feed(eqc_meter *m, const float *first, const float *second, int32_t frames) {
    int32_t bands = m->spectrumBands;
    float attack = m->attack, release = m->release;
    for (int32_t frame = 0; frame < frames; frame++)
        meter_bands(0.5f * (first[frame] + second[frame]), m->spectrumStates, m->spectrumEnvelopes, m->spectrumCoefficients, bands,
                    attack, release);
    for (int32_t i = 0; i < bands; i++) {
        eqc_biquad_state *state = &m->spectrumStates[i];
        if (!isfinite(m->spectrumEnvelopes[i]) || !isfinite(state->z1) || !isfinite(state->z2)) {
            m->spectrumEnvelopes[i] = 0;
            *state = (eqc_biquad_state){0, 0};
        }
        flush(state);
        if (m->spectrumEnvelopes[i] < FLT_MIN) m->spectrumEnvelopes[i] = 0;
        store_level(&m->spectrumLevels[i], decibels(m->spectrumEnvelopes[i]));
    }
}

void eqc_meter_feed_spectrum(eqc_meter *m, const eqc_channel *output, int32_t outputChannels, int32_t frames) {
    if (outputChannels < 1) return;
    spectrum_feed(m, output[0], outputChannels > 1 ? output[1] : output[0], frames);
}

void eqc_meter_read_spectrum(const eqc_meter *m, double *levels) {
    for (int32_t i = 0; i < EQC_SPECTRUM_BANDS; i++) levels[i] = load_level(&m->spectrumLevels[i]);
}

int32_t eqc_meter_band_count(const eqc_meter *m) { return m->bandCount; }

void eqc_meter_read(const eqc_meter *m, double *input, double *output, double *peak) {
    for (int32_t i = 0; i < m->bandCount; i++) {
        input[i] = load_level(&m->levels[i]);
        output[i] = load_level(&m->levels[m->bandCount + i]);
    }
    *peak = load_level(&m->peakLevel);
}

int32_t eqc_meter_render_state(const eqc_meter *m, float *out, int32_t capacity) {
    int32_t n = 0;
    for (int32_t i = 0; i < 2 * m->bandCount; i++) {
        if (n + 3 > capacity) return n;
        out[n++] = m->states[i].z1;
        out[n++] = m->states[i].z2;
        out[n++] = m->envelopes[i];
    }
    if (n < capacity) out[n++] = m->peakEnvelope;
    return n;
}

// MARK: - Engine

typedef struct {
    eqc_biquad sections[EQC_MAX_SECTIONS];
    int32_t sectionCount;
    // What the filter history is sized for when this program is picked up.
    int32_t channelCount;
    float preampLinear, outputGainLinear;
    bool limiterEnabled;
    float limiterCeilingLinear;
    bool bypassed;
    eqc_dynamics dynamics;
} program;

#define FRESH 4

struct eqc_engine {
    // A triple buffer: the publisher fills programs[back], then swaps it into `middle` marked
    // FRESH; the render thread swaps a FRESH middle for its front. Neither ever waits.
    program programs[3];
    int32_t front, back, middle;

    eqc_settings settings;
    bool hasSettings;
    double sampleRate;
    int32_t channelCount;

    // Render thread only, but for the atomics marked below.
    eqc_biquad_state states[EQC_MAX_CHANNELS][EQC_MAX_SECTIONS];
    int32_t stateChannels;
    float limiterEnvelope, limiterRelease;
    eqc_dynamics_state dynamicsState;
    eqc_biquad_state detector[2 * EQC_MAX_CHANNELS];
    float dc[2 * EQC_MAX_CHANNELS];
    bool wasMetering, wasSpectrum;
    int32_t metering;           // atomic
    int32_t spectrum;           // atomic
    int32_t limiting;           // atomic
    float compressorReductionDB; // atomic
    eqc_meter meter;
    float meterInput[EQC_METER_CAPACITY];
};

size_t eqc_engine_size(void) { return sizeof(eqc_engine); }

static program default_program(void) {
    program p = {0};
    p.channelCount = 2;
    p.preampLinear = 1;
    p.outputGainLinear = 1;
    p.limiterEnabled = true;
    p.limiterCeilingLinear = (float)pow(10, -1.0 / 20);
    p.dynamics = dynamics_off();
    return p;
}

static inline void store_float(float *cell, float value) { __atomic_store(cell, &value, __ATOMIC_RELAXED); }

void eqc_engine_init(eqc_engine *e, const double *meterFrequencies, int32_t meterBands) {
    for (int i = 0; i < 3; i++) e->programs[i] = default_program();
    e->front = 0;
    e->middle = 1;
    e->back = 2;
    e->hasSettings = false;
    e->sampleRate = 48000;
    e->channelCount = 2;
    for (int32_t ch = 0; ch < EQC_MAX_CHANNELS; ch++)
        for (int32_t s = 0; s < EQC_MAX_SECTIONS; s++) e->states[ch][s] = (eqc_biquad_state){0, 0};
    e->stateChannels = 2;
    e->limiterEnvelope = 0;
    e->limiterRelease = (float)exp(-1.0 / (0.080 * 48000));
    e->dynamicsState = (eqc_dynamics_state){0};
    for (int32_t i = 0; i < 2 * EQC_MAX_CHANNELS; i++) {
        e->detector[i] = (eqc_biquad_state){0, 0};
        e->dc[i] = 0;
    }
    e->wasMetering = false;
    e->wasSpectrum = false;
    e->metering = 0;
    e->spectrum = 0;
    e->limiting = 0;
    e->compressorReductionDB = 0;
    eqc_meter_init(&e->meter, meterFrequencies, meterBands);
    for (int32_t i = 0; i < EQC_METER_CAPACITY; i++) e->meterInput[i] = 0;
}

static int32_t prepare(program *p, const eqc_settings *s, double rate, int32_t channels, int32_t *unstable) {
    int32_t unstableCount = 0;
    int32_t bandCount = s->bandCount < 0 ? 0 : s->bandCount > EQC_MAX_BANDS ? EQC_MAX_BANDS : s->bandCount;
    double soloLow = 0, soloHigh = 0;
    bool solo = s->solo && eqc_clamp_solo(s->soloLow, s->soloHigh, rate, &soloLow, &soloHigh);
    int32_t n = 0;
    for (int32_t i = 0; i < bandCount; i++) {
        const eqc_band *band = &s->bands[i];
        if (!band->enabled) continue;
        eqc_biquad c = eqc_design(band->type, band->frequency, band->gainDB, band->q, rate);
        // Settings are validated at 48 kHz only; at 96/192 kHz float rounding pushes some in-range
        // filters below ~28 Hz onto the unit circle, and one would ring forever.
        if (!eqc_biquad_is_stable(c)) {
            if (unstable) unstable[unstableCount] = i;
            unstableCount++;
            c = identity;
        }
        p->sections[n++] = c;
    }
    if (solo) {
        // Listening to a range with the EQ switched off still has to isolate it, so the user's
        // curve is dropped but the solo pair runs.
        if (s->bypassed) n = 0;
        // Two 2nd-order Butterworth sections per edge: a 4th-order slope, -6 dB at the edge itself.
        double q = sqrt(0.5);
        eqc_biquad hp = eqc_design(EQC_HIGH_PASS, soloLow, 0, q, rate);
        eqc_biquad lp = eqc_design(EQC_LOW_PASS, soloHigh, 0, q, rate);
        if (!eqc_biquad_is_stable(hp)) hp = identity;
        if (!eqc_biquad_is_stable(lp)) lp = identity;
        p->sections[n++] = hp;
        p->sections[n++] = hp;
        p->sections[n++] = lp;
        p->sections[n++] = lp;
    }
    p->sectionCount = n;
    p->channelCount = channels;
    p->preampLinear = s->bypassed ? 1 : (float)pow(10, s->preampDB / 20);
    p->outputGainLinear = s->bypassed ? 1 : (float)pow(10, s->outputGainDB / 20);
    p->limiterEnabled = s->limiterEnabled;
    p->limiterCeilingLinear = (float)pow(10, s->limiterCeilingDB / 20);
    p->bypassed = s->bypassed && !solo;
    p->dynamics = s->bypassed ? eqc_dynamics_design(EQC_COMPRESSOR_OFF, EQC_COLOUR_OFF, 0, rate)
                              : eqc_dynamics_design(s->compressor, s->colour, s->colourAmount, rate);
    return unstableCount;
}

static int32_t publish(eqc_engine *e, int32_t *unstable) {
    int32_t count = prepare(&e->programs[e->back], &e->settings, e->sampleRate, e->channelCount, unstable);
    e->back = __atomic_exchange_n(&e->middle, e->back | FRESH, __ATOMIC_ACQ_REL) & ~FRESH;
    return count;
}

int32_t eqc_update(eqc_engine *e, const eqc_settings *settings, int32_t *unstable) {
    e->settings = *settings;
    e->hasSettings = true;
    return publish(e, unstable);
}

void eqc_configure(eqc_engine *e, double sampleRate, int32_t channels) {
    e->sampleRate = sampleRate;
    e->channelCount = channels < 1 ? 1 : channels > EQC_MAX_CHANNELS ? EQC_MAX_CHANNELS : channels;
    e->limiterRelease = (float)exp(-1.0 / (0.080 * sampleRate));
    eqc_meter_configure(&e->meter, sampleRate);
    if (e->hasSettings) publish(e, NULL);
}

void eqc_set_metering(eqc_engine *e, bool enabled) { __atomic_store_n(&e->metering, enabled ? 1 : 0, __ATOMIC_RELAXED); }
void eqc_set_spectrum(eqc_engine *e, bool enabled) { __atomic_store_n(&e->spectrum, enabled ? 1 : 0, __ATOMIC_RELAXED); }
bool eqc_limiting(const eqc_engine *e) { return __atomic_load_n(&e->limiting, __ATOMIC_RELAXED) != 0; }

float eqc_compressor_reduction_db(const eqc_engine *e) {
    float value;
    __atomic_load(&e->compressorReductionDB, &value, __ATOMIC_RELAXED);
    return value;
}

eqc_meter *eqc_engine_meter(eqc_engine *e) { return &e->meter; }

CLEARS static void clear_states(eqc_engine *e, int32_t channels, int32_t sections) {
    for (int32_t ch = 0; ch < channels; ch++)
        for (int32_t s = 0; s < sections; s++) e->states[ch][s] = (eqc_biquad_state){0, 0};
}

CLEARS static void reset_detector(eqc_engine *e) {
    e->dynamicsState.meanSquare = 0;
    e->dynamicsState.averageReductionDB = 0;
    for (int32_t i = 0; i < 2 * EQC_MAX_CHANNELS; i++) e->detector[i] = (eqc_biquad_state){0, 0};
}

CLEARS static void reset_dynamics(eqc_engine *e) {
    e->dynamicsState = (eqc_dynamics_state){0};
    store_float(&e->compressorReductionDB, 0);
    reset_detector(e);
    for (int32_t i = 0; i < 2 * EQC_MAX_CHANNELS; i++) e->dc[i] = 0;
}

void eqc_reset_render_state(eqc_engine *e) {
    const program *p = &e->programs[e->front];
    clear_states(e, e->stateChannels, p->sectionCount);
    e->limiterEnvelope = 0;
    float averageReductionDB = e->dynamicsState.averageReductionDB;
    reset_dynamics(e);
    e->dynamicsState.averageReductionDB = averageReductionDB;
    eqc_meter_reset(&e->meter);
}

static void render(eqc_engine *e, const eqc_channel *channels, int32_t channelCount, int32_t frames) {
    bool limiting = false;
    bool swapped = false;
    if (__atomic_load_n(&e->middle, __ATOMIC_RELAXED) & FRESH) {
        e->front = __atomic_exchange_n(&e->middle, e->front, __ATOMIC_ACQ_REL) & ~FRESH;
        swapped = true;
    }
    const program *p = &e->programs[e->front];
    if (swapped) {
        clear_states(e, p->channelCount, p->sectionCount);
        e->stateChannels = p->channelCount;
        // A compressor switched off glides its gain out but has no more use for its detector, so
        // switching back on starts listening afresh. Bypass is a jump anyway, and after it nothing
        // should still be gliding out of what played before.
        if (p->bypassed) reset_dynamics(e);
        if (!p->dynamics.compressor) reset_detector(e);
    }
    if (p->bypassed) {
        __atomic_store_n(&e->limiting, 0, __ATOMIC_RELAXED);
        return;
    }

    const eqc_dynamics *dynamics = &p->dynamics;
    const eqc_biquad *sections = p->sections;
    int32_t sectionCount = p->sectionCount;
    float preampLinear = p->preampLinear, outputGainLinear = p->outputGainLinear;
    bool limiterEnabled = p->limiterEnabled;
    float ceiling = p->limiterCeilingLinear, release = e->limiterRelease;
    bool shaping = dynamics_active(dynamics) || !dynamics_idle(&e->dynamicsState);

    // The history is sized for the configured channel count; another count starts it afresh.
    if (channelCount * sectionCount != e->stateChannels * sectionCount) {
        clear_states(e, channelCount, sectionCount);
        e->stateChannels = channelCount;
        e->limiterEnvelope = 0;
    }

    float envelope = e->limiterEnvelope;
    for (int32_t frame = 0; frame < frames; frame++) {
        // Stereo-linked limiter: the loudest post-EQ sample across channels.
        float maxMag = 0;
        for (int32_t ch = 0; ch < channelCount; ch++) {
            float sample = channels[ch][frame] * preampLinear;
            eqc_biquad_state *states = e->states[ch];
            for (int32_t s = 0; s < sectionCount; s++) sample = biquad(&states[s], sample, &sections[s]);
            sample *= outputGainLinear;
            channels[ch][frame] = sample;
            maxMag = fmaxs(maxMag, fabsf(sample));
        }
        if (shaping) maxMag = dynamics_frame(dynamics, channels, frame, channelCount, &e->dynamicsState, e->detector, e->dc);
        if (limiterEnabled) {
            // Instant attack: a lagging envelope let onsets through above 0 dBFS and the DAC clipped them.
            envelope = maxMag > envelope ? maxMag : release * envelope + (1 - release) * maxMag;
            if (envelope > ceiling) {
                limiting = true;
                float gain = ceiling / envelope;
                for (int32_t ch = 0; ch < channelCount; ch++) channels[ch][frame] *= gain;
            }
        }
    }
    for (int32_t ch = 0; ch < channelCount; ch++)
        for (int32_t s = 0; s < sectionCount; s++) flush(&e->states[ch][s]);
    e->limiterEnvelope = envelope < FLT_MIN ? 0 : envelope;
    if (shaping) {
        for (int32_t i = 0; i < 2 * channelCount; i++) {
            flush(&e->detector[i]);
            if (fabsf(e->dc[i]) < FLT_MIN) e->dc[i] = 0;
        }
        flush_tails(&e->dynamicsState, dynamics->compressor);
        store_float(&e->compressorReductionDB, e->dynamicsState.reductionDB);
    }
    __atomic_store_n(&e->limiting, limiting ? 1 : 0, __ATOMIC_RELAXED);
}

static void sanitize(const eqc_channel *channels, int32_t channelCount, int32_t frames) {
    for (int32_t ch = 0; ch < channelCount; ch++)
        for (int32_t frame = 0; frame < frames; frame++)
            if (!isfinite(channels[ch][frame])) channels[ch][frame] = 0;
}

// x - x is 0 for a finite x and NaN otherwise, so one sum answers for all the history at once
// without a finite-but-huge value overflowing it.
static bool render_state_finite(const eqc_engine *e) {
    const program *p = &e->programs[e->front];
    const eqc_dynamics_state *d = &e->dynamicsState;
    float sum = 0;
    for (int32_t ch = 0; ch < e->stateChannels; ch++)
        for (int32_t s = 0; s < p->sectionCount; s++) {
            const eqc_biquad_state *state = &e->states[ch][s];
            sum += (state->z1 - state->z1) + (state->z2 - state->z2);
        }
    for (int32_t i = 0; i < 2 * EQC_MAX_CHANNELS; i++)
        sum += (e->detector[i].z1 - e->detector[i].z1) + (e->detector[i].z2 - e->detector[i].z2) + (e->dc[i] - e->dc[i]);
    sum += e->limiterEnvelope - e->limiterEnvelope;
    sum += (d->meanSquare - d->meanSquare) + (d->reductionDB - d->reductionDB) +
           (d->averageReductionDB - d->averageReductionDB) + (d->makeupDB - d->makeupDB) + (d->drive - d->drive);
    return sum == 0;
}

// Finite input can still overflow the history, with an absurd gain say; left alone, a NaN there
// would silence every later call. What this call produced is lost with it.
CLEARS static void recover(eqc_engine *e, const eqc_channel *channels, int32_t channelCount, int32_t frames) {
    clear_states(e, EQC_MAX_CHANNELS, EQC_MAX_SECTIONS);
    e->limiterEnvelope = 0;
    reset_dynamics(e);
    __atomic_store_n(&e->limiting, 0, __ATOMIC_RELAXED);
    for (int32_t ch = 0; ch < channelCount; ch++)
        for (int32_t frame = 0; frame < frames; frame++) channels[ch][frame] = 0;
}

void eqc_process(eqc_engine *e, const eqc_channel *channels, int32_t channelCount, int32_t frames) {
    if (channelCount > EQC_MAX_CHANNELS) channelCount = EQC_MAX_CHANNELS;
    if (channelCount < 0) channelCount = 0;
    sanitize(channels, channelCount, frames);
    bool metering = __atomic_load_n(&e->metering, __ATOMIC_RELAXED) && frames <= EQC_METER_CAPACITY && channelCount > 0;
    bool spectrum = metering && __atomic_load_n(&e->spectrum, __ATOMIC_RELAXED);
    if (metering && !e->wasMetering) eqc_meter_reset(&e->meter);
    else if (spectrum && !e->wasSpectrum) spectrum_reset(&e->meter);
    e->wasMetering = metering;
    e->wasSpectrum = spectrum;
    if (metering) {
        const float *left = channels[0];
        const float *right = channelCount > 1 ? channels[1] : left;
        for (int32_t frame = 0; frame < frames; frame++) e->meterInput[frame] = 0.5f * (left[frame] + right[frame]);
    }
    render(e, channels, channelCount, frames);
    if (!render_state_finite(e)) recover(e, channels, channelCount, frames);
    if (metering) {
        meter_feed(&e->meter, e->meterInput, e->meterInput, channels[0], channelCount > 1 ? channels[1] : channels[0], frames);
    }
    if (spectrum) spectrum_feed(&e->meter, channels[0], channelCount > 1 ? channels[1] : channels[0], frames);
}

int32_t eqc_engine_render_state(const eqc_engine *e, float *out, int32_t capacity) {
    const program *p = &e->programs[e->front];
    int32_t n = 0;
#define PUT(v) do { if (n < capacity) out[n++] = (v); } while (0)
    for (int32_t ch = 0; ch < e->stateChannels; ch++)
        for (int32_t s = 0; s < p->sectionCount; s++) {
            PUT(e->states[ch][s].z1);
            PUT(e->states[ch][s].z2);
        }
    PUT(e->limiterEnvelope);
    PUT(e->dynamicsState.meanSquare);
    PUT(e->dynamicsState.reductionDB);
    for (int32_t i = 0; i < 2 * EQC_MAX_CHANNELS; i++) {
        PUT(e->detector[i].z1);
        PUT(e->detector[i].z2);
        PUT(e->dc[i]);
    }
#undef PUT
    return n;
}
