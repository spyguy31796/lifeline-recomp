// Unit test for the FMV skip decision (no game data). Run by steam-machine/tests/run-unit-tests.sh, or:
//   clang++ -std=c++20 -I.. test_fmv_skip.cpp && ./a.out
#include "fmv_skip.hpp"
#include <cstdio>
using namespace fmv;
static int fails = 0;
#define CHECK(x) do { if (!(x)) { std::printf("FAIL line %d: %s\n", __LINE__, #x); ++fails; } } while (0)
static SkipLogic::Why w;
static bool up(SkipLogic &s, std::uint32_t st, std::uint32_t open, std::uint16_t b, bool busy = false) { return s.update(st, open, b, busy, w); }

int main() {
    {   // Start skips; held-before-play doesn't count
        SkipLogic s;
        CHECK(!up(s, 1, 1, kStart));           // opening: never
        CHECK(!up(s, 5, 1, kStart));           // first playing call arms; Start already held does not count
        CHECK(!up(s, 5, 1, kStart));           // still held
        CHECK(!up(s, 5, 1, 0));
        CHECK(up(s, 5, 1, kStart));            // new press: skip
        CHECK(!up(s, 6, 1, kStart));           // ending: nothing more
    }
    {   // Cross is confirm: never skips (alone, or held into a Start press it doesn't block)
        SkipLogic x;
        CHECK(!up(x, 5, 1, 0));
        CHECK(!up(x, 5, 1, kCross));
        CHECK(!up(x, 5, 1, 0));
        CHECK(up(x, 5, 1, kCross | kStart));   // a real Start press still skips
    }
    {   // circle never skips, nor Start while circle is held
        SkipLogic c;
        CHECK(!up(c, 5, 1, 0));
        CHECK(!up(c, 5, 1, kCircle));
        CHECK(!up(c, 5, 1, kCircle | kStart));
        CHECK(!up(c, 5, 1, 0) && up(c, 5, 1, kStart));
    }
    {   // voice busy: refused (reason reported), and that press is used up
        SkipLogic v;
        CHECK(!up(v, 5, 1, 0));
        CHECK(!up(v, 5, 1, kStart, true) && w == SkipLogic::Why::Voice);
        CHECK(!up(v, 5, 1, kStart, false) && w == SkipLogic::Why::None);   // still the same press
        CHECK(!up(v, 5, 1, 0) && up(v, 5, 1, kStart, false));              // a new press once idle
    }
    {   // stream not open: never
        SkipLogic o;
        CHECK(!up(o, 5, 0, 0) && !up(o, 5, 0, kStart));
    }
    {   // other buttons ignored
        SkipLogic t;
        CHECK(!up(t, 5, 1, 0));
        CHECK(!up(t, 5, 1, 1u << 12) && !up(t, 5, 1, 1u << 15) && !up(t, 5, 1, 1u << 0));   // triangle, square, select
    }
    {   // second movie on the same player re-arms: Start held from the first skip does not skip the next one
        SkipLogic m;
        CHECK(!up(m, 5, 1, 0) && up(m, 5, 1, kStart));   // movie 1 skipped
        CHECK(!up(m, 6, 1, kStart) && !up(m, 9, 0, kStart) && !up(m, 0, 0, kStart));
        CHECK(!up(m, 5, 1, kStart));                      // movie 2 starts with Start still held: arms only
        CHECK(!up(m, 5, 1, kStart));
        CHECK(!up(m, 5, 1, 0) && up(m, 5, 1, kStart));   // new press skips movie 2
    }
    {   // state load: clear() drops the latch, a Start held across the load does not skip
        SkipLogic l;
        CHECK(!up(l, 5, 1, 0));
        l.clear();
        CHECK(!up(l, 5, 1, kStart));                      // re-arms with Start down
        CHECK(!up(l, 5, 1, kStart));
        CHECK(!up(l, 5, 1, 0) && up(l, 5, 1, kStart));
    }
    // only the full-screen movie object's Execute call is skippable, never the in-scene slot array
    CHECK(skippable_caller(kFullscreenReturn));
    CHECK(!skippable_caller(kSlotArrayReturn));
    CHECK(!skippable_caller(0));
    CHECK(kSkipButtons == kStart && !(kSkipButtons & (kCross | kCircle)));
    std::puts(fails ? "test_fmv_skip: FAILED" : "test_fmv_skip: ok");
    return fails != 0;
}
