#!/bin/zsh
# CPU of EQCore's resampler: one minute of 128-frame buffers per rate pair, the ratio moving every
# buffer as the route servo moves it. Prints the share of one core it takes in real time.
set -euo pipefail
cd "${0:a:h}/.."
scratch=$(mktemp -d /tmp/eq-bench.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/bench.c" <<'C'
#include "EQResampler.h"
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void bench(double in, double out, int channels) {
    size_t size = eqc_resampler_size(in, out, channels, 4096);
    eqc_resampler *r = aligned_alloc(16, (size + 15) & ~(size_t)15);
    eqc_resampler_init(r, in, out, channels, 4096);
    float *buffers[16];
    for (int c = 0; c < channels; c++) buffers[c] = malloc(sizeof(float) * 4096);
    float source[8192];
    for (int i = 0; i < 8192; i++) source[i] = sinf(i * 0.01f);
    long total = (long)(out * 60), done = 0;
    uint64_t start = mach_absolute_time();
    while (done < total) {
        int needed = eqc_resampler_needed(r, 128);
        for (int c = 0; c < channels; c++) {
            float *input = eqc_resampler_input(r, c);
            for (int i = 0; i < needed; i++) input[i] = source[i];
        }
        eqc_resampler_produce(r, needed, buffers, 128);
        done += 128;
        eqc_resampler_set_correction(r, (done % 7) * 1e-5);
    }
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    double seconds = (double)(mach_absolute_time() - start) * base.numer / base.denom / 1e9;
    printf("%6.0f → %6.0f Hz, %2d ch, %3d taps: %.3f%% of one core (%.1f ns a frame)\n",
           in, out, channels, eqc_resampler_taps(r), seconds / 60 * 100, seconds / total * 1e9);
}

int main(void) {
    bench(48000, 44100, 2);
    bench(44100, 48000, 2);
    bench(44100, 44100, 2);
    bench(96000, 44100, 2);
    bench(48000, 44100, 8);
    return 0;
}
C
for opt in -O2 -Os; do
  echo "clang $opt"
  xcrun clang $opt -std=c11 -ISources/EQCore/include Sources/EQCore/EQResampler.c "$scratch/bench.c" -o "$scratch/bench"
  "$scratch/bench"
done
