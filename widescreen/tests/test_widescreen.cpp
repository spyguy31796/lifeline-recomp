// Unit test for the widescreen setter + per-frame guard (no game data).
// Build: clang++ -std=c++20 -I.. test_widescreen.cpp
#include "widescreen.hpp"
#include <cstdio>
using namespace widescreen;
static int fails = 0;
#define CHECK(x) do { if (!(x)) { std::printf("FAIL: %s\n", #x); ++fails; } } while (0)

struct Camera { std::uint32_t x = bits(1.0f); };
static void setter(Camera &cam, std::uint32_t f12, bool hooked) {   // 0x1CA208
    if (hooked) f12 = widen_arg(f12);
    if (from_bits(f12) > 0.0f) cam.x = f12;
}
static void frame(Camera &cam, bool hooked) {                       // 0x1CA928
    if (!hooked) return;
    if (std::uint32_t v; widen_field(cam.x, v)) cam.x = v;
}

int main() {
    CHECK(from_bits(widen_arg(bits(1.0f))) == 0.75f);
    CHECK(widen_arg(bits(0.0f)) == bits(0.0f));
    CHECK(widen_arg(0x7fc00000u) == 0x7fc00000u);
    CHECK(widen_arg(bits(100.0f)) == bits(100.0f));

    std::uint32_t o = 0;
    CHECK(widen_field(bits(1.0f), o) && from_bits(o) == 0.75f);      // game value widened
    CHECK(!widen_field(bits(0.75f), o));                             // already ours: leave alone
    CHECK(!widen_field(bits(0.0f), o));
    CHECK(!widen_field(0x7fc00000u, o));

    Camera c;
    setter(c, bits(1.0f), true);
    CHECK(from_bits(c.x) == 0.75f);                                  // setter path
    frame(c, true);
    CHECK(from_bits(c.x) == 0.75f);                                  // per-frame leaves 0.75 alone
    setter(c, bits(1.0f), true);
    CHECK(from_bits(c.x) == 0.75f);                                  // camera re-init via setter

    Camera loaded; loaded.x = bits(0.75f);                           // state saved with widescreen on,
    for (int i = 0; i < 300; ++i) frame(loaded, true);              // loaded in a fresh process
    CHECK(from_bits(loaded.x) == 0.75f);                             // must stay 0.75, not 0.5625
    setter(loaded, bits(1.0f), true);
    CHECK(from_bits(loaded.x) == 0.75f);

    Camera from_narrow;                                             // state saved with widescreen off
    for (int i = 0; i < 3; ++i) frame(from_narrow, true);
    CHECK(from_bits(from_narrow.x) == 0.75f);                        // per-frame guard widens it once

    Camera off; setter(off, bits(1.0f), false); frame(off, false);
    CHECK(from_bits(off.x) == 1.0f);

    std::puts(fails ? "test_widescreen: FAILED" : "test_widescreen: ok");
    return fails != 0;
}
