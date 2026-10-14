// Unit test for host/ff_pacing.hpp (added by 0010-fast-forward.patch): the fast-forward speed cap, fake clock.
// Build against a patched ps2-web-recomp tree:
//   c++ -std=c++20 -I<tree>/host tests/test_ff_pacing.cpp -o /tmp/tff && /tmp/tff
#include "ff_pacing.hpp"
#include <cstdio>
#include <initializer_list>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { std::printf("FAIL line %d: ", __LINE__); std::printf(__VA_ARGS__); std::printf("\n"); ++fails; } } while (0)

// Simulates `seconds` of FF frames that each cost `cost_us` of work; SDL_Delay(ms) sleeps exactly ms (+ oversleep_us).
static double run(unsigned mult, unsigned base_fps, double cost_us, double oversleep_us, double seconds, std::uint64_t frequency) {
    ff_pacing::Limiter lim;
    const std::uint64_t period = frequency / (base_fps * mult);
    double now_s = 1.0;   // nonzero counter
    unsigned frames = 0;
    const double end = now_s + seconds;
    while (now_s < end) {
        now_s += cost_us / 1e6;                                   // the frame's work
        const std::uint32_t ms = lim.step(static_cast<std::uint64_t>(now_s * frequency), period, frequency);
        if (ms) now_s += ms / 1e3 + oversleep_us / 1e6;          // SDL_Delay
        ++frames;
    }
    return frames / seconds;
}

int main() {
    for (std::uint64_t freq : {1000000000ull, 1000000ull, 24000000ull}) {   // ns clock (Linux SDL), us, odd
        for (unsigned mult : {4u, 8u, 16u}) {
            for (unsigned base : {60u, 50u}) {
                const double cap = base * mult;
                for (double cost : {0.0, 50.0, 500.0, 2000.0}) {   // cheap frames, as in the Lead's repro
                    const double fps = run(mult, base, cost, 0.0, 20.0, freq);
                    CHECK(fps <= cap * 1.005, "%ux @%u Hz, cost %.0f us, freq %llu: %.1f fps > cap %.0f", mult, base, cost, (unsigned long long)freq, fps, cap);
                    if (cost * cap < 0.8e6) CHECK(fps >= cap * 0.97, "%ux @%u, cost %.0f us: %.1f fps, far below cap %.0f", mult, base, cost, fps, cap);
                }
                // a scheduler that oversleeps 300 us still holds the cap and gets close to it
                const double o = run(mult, base, 50.0, 300.0, 20.0, freq);
                CHECK(o <= cap * 1.005, "oversleep %ux: %.1f > %.0f", mult, o, cap);
            }
        }
    }
    // slow frames (slower than the cap): no sleeping, and no catch-up burst afterwards
    {
        const std::uint64_t f = 1000000000ull, period = f / 240;
        ff_pacing::Limiter lim; std::uint64_t now = f; lim.step(now, period, f);   // first FF frame
        for (int i = 0; i < 50; ++i) { now += period * 3; CHECK(lim.step(now, period, f) == 0, "slow frame %d slept", i); }
        // then cheap frames: the very next frame must already wait (deadline resynced, not 100 periods behind)
        now += 1000; CHECK(lim.step(now, period, f) > 0, "burst after slow frames");
    }
    // first frame never sleeps a whole period from a zero start; reset() restarts
    {
        ff_pacing::Limiter lim; const std::uint64_t f = 1000000ull, period = f / 240;
        CHECK(lim.step(5 * f, period, f) == 5, "first frame waits one period, rounded up (4.17 ms -> 5)");
        lim.reset(); CHECK(lim.last == 0, "reset");
    }
    std::printf(fails ? "%d FAILED\n" : "all ff_pacing tests passed\n", fails);
    return fails != 0;
}
