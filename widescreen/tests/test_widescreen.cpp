// Unit test for the widescreen aspect tracker (no game data). Build: clang++ -std=c++20 -I.. test_widescreen.cpp
#include "widescreen.hpp"
#include <cstdio>
using namespace widescreen;
static int fails = 0;
#define CHECK(x) do { if (!(x)) { std::printf("FAIL: %s\n", #x); ++fails; } } while (0)
int main() {
    Tracker t; std::uint32_t o = 0;
    CHECK(t.update(0x38d380, bits(1.0f), o) && from_bits(o) == 0.75f);   // game value widened
    CHECK(!t.update(0x38d380, o, o));                                    // our value left alone
    CHECK(t.update(0x38d380, bits(1.0f), o) && from_bits(o) == 0.75f);   // camera re-init: widened again
    CHECK(t.update(0x400000, bits(1.0f), o));                            // second camera tracked separately
    CHECK(!t.update(0x500000, bits(0.0f), o));                           // not a valid aspect: untouched
    CHECK(!t.update(0x500000, 0x7fc00000u, o));                          // NaN: untouched
    std::puts(fails ? "test_widescreen: FAILED" : "test_widescreen: ok");
    return fails != 0;
}
