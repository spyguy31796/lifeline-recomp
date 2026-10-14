// Unit test for host/audio_pacing.hpp (added by 0004-audio-buffer-and-perf-log.patch).
// Build against a patched ps2-web-recomp tree:
//   c++ -std=c++20 -I<tree>/host tests/test_audio_pacing.cpp -o /tmp/tap && /tmp/tap
#include "audio_pacing.hpp"
#include <cstdio>
using namespace audio_pacing;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++fails; } } while (0)
int main() {
    // (1) parsing: bad -> default with warning, good -> clamped
    CHECK(env_int("B", nullptr, 120, 20, 400) == 120);
    for (const char *bad : {"abc", "", "-5", "0", "1e3", "12ms", " 50", "99999999999999999999999", "0x40"})
        CHECK(env_int("B", bad, 120, 20, 400) == 120);
    CHECK(env_int("B", "200", 120, 20, 400) == 200);
    CHECK(env_int("B", "5", 120, 20, 400) == 20);
    CHECK(env_int("B", "1000", 120, 20, 400) == 400);
    CHECK(env_int("S", "2048", 1024, 256, 8192, true) == 2048);
    CHECK(env_int("S", "1000", 1024, 256, 8192, true) == 1024);   // not a power of two
    CHECK(env_int("S", "abc", 1024, 256, 8192, true) == 1024);
    CHECK(env_int("S", "65536", 1024, 256, 8192, true) == 8192);
    // (2) starvation: a queue stuck at ~17 ms (< one 1024-frame buffer = 4096 B = 21.3 ms) counts every frame
    const std::uint32_t buf = 1024 * 4, per_ms = 48 * 4;
    Stats s;
    s.frame(0, buf); CHECK(s.starved_frames == 0);                  // boot, nothing fed yet
    for (int i = 0; i < 60; ++i) s.frame(17 * per_ms, buf);
    CHECK(s.starved_frames == 60 && s.starve_events == 1);
    for (int i = 0; i < 10; ++i) s.frame(100 * per_ms, buf);        // recovered
    CHECK(s.starved_frames == 60 && !s.starving);
    s.frame(0, buf); s.frame(5 * per_ms, buf);                      // a dropout
    CHECK(s.starved_frames == 62 && s.starve_events == 2);
    // (3) cap: target + two device buffers
    CHECK(cap_bytes(400, buf, per_ms) / per_ms == 442);             // 400 ms + 2 x 21.3 ms
    CHECK(cap_bytes(120, buf, per_ms) / per_ms == 162);
    CHECK(cap_bytes(400, 8192 * 4, per_ms) / per_ms < 820);         // even with the largest buffer
    // target below 2x device buffer is raised (no false starvation with short targets)
    CHECK(effective_target_ms(20, buf, per_ms) == 43);              // 2 x 21.33 ms, rounded up
    CHECK(effective_target_ms(43, buf, per_ms) == 43);
    CHECK(effective_target_ms(120, buf, per_ms) == 120);
    CHECK(effective_target_ms(120, 8192 * 4, per_ms) == 342);      // 2 x 170.67 ms
    CHECK(effective_target_ms(400, 8192 * 4, per_ms) == 400);
    {   // at the raised target a full queue minus one device pull is not starved
        Stats t; const std::uint32_t tgt = effective_target_ms(20, buf, per_ms);
        for (int i = 0; i < 30; ++i) t.frame(tgt * per_ms - buf, buf);
        CHECK(t.starved_frames == 0);
    }
    std::printf(fails ? "%d FAILED\n" : "all audio_pacing tests passed\n", fails);
    return fails != 0;
}
