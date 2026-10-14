// c++ -std=c++20 -I.. test_listen_reset.cpp && ./a.out
#include "listen_reset.hpp"
#include <cstdio>
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++fails; } } while (0)
int main() {
    using voice::ListenReset;
    { ListenReset r; r.on_load(100, false); CHECK(!r.armed()); CHECK(!r.on_execute(100, false)); }        // normal load doesn't arm
    { ListenReset r; r.on_load(100, true); CHECK(r.armed()); CHECK(r.on_execute(101, false)); CHECK(!r.armed()); CHECK(!r.on_execute(102, false)); }
    { ListenReset r; r.on_load(100, true); CHECK(!r.on_execute(100 + ListenReset::kMaxFrames + 1, false)); CHECK(!r.armed()); }   // expires
    { ListenReset r; r.on_load(100, true); CHECK(r.on_execute(100 + ListenReset::kMaxFrames, false)); }
    { ListenReset r; r.on_load(100, true); CHECK(!r.on_execute(101, true)); CHECK(!r.armed()); }          // our side listening: no clear
    { ListenReset r; r.on_load(100, true); r.on_command(); CHECK(!r.armed()); CHECK(!r.on_execute(101, false)); }   // cmd 1/2 disarms
    { ListenReset r; r.on_load(100, true); r.on_load(200, false); CHECK(!r.armed()); }                    // next load disarms
    std::printf(fails ? "%d FAILED\n" : "listen_reset: all passed\n", fails);
    return fails != 0;
}
