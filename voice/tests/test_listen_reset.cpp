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
    // Restored held mask vs the real Circle after the reset: only the Circle bit changes, until it catches up.
    { ListenReset r; CHECK(r.resync_held(0x20, 0x20, false) == 0x20); }                     // not started: untouched
    { ListenReset r; r.start_resync();
      CHECK(r.resync_held(0x8020, 0x20, false) == 0x8000);   // stale held, real up: no listen on the load frame
      CHECK(r.resyncing());
      CHECK(r.resync_held(0x20, 0x20, false) == 0);           // still stale next frame: still kept up
      CHECK(r.resync_held(0x0, 0x20, false) == 0x0); CHECK(!r.resyncing());   // game caught up: done
      CHECK(r.resync_held(0x20, 0x20, false) == 0x20); }      // later presses are the game's own
    { ListenReset r; r.start_resync(); CHECK(r.resync_held(0x20, 0x20, true) == 0x20); CHECK(!r.resyncing()); }   // real press
    { ListenReset r; r.start_resync(); r.on_load(300, false); CHECK(!r.resyncing()); }                            // next load
    // The hold log fires once per resync, and again after a new resync even if the last one was cancelled.
    { ListenReset r; r.start_resync(); CHECK(r.note_hold_once()); CHECK(!r.note_hold_once());
      r.cancel_resync(); r.start_resync(); CHECK(r.note_hold_once()); }
    // Pad record pointer bounds before the write.
    CHECK(!ListenReset::pad_word_ok(0, 0x1E4));
    CHECK(ListenReset::pad_word_ok(0x00400000, 0x1E4));
    CHECK(ListenReset::pad_word_ok(0x20400000, 0x1E4));                 // uncached mirror
    CHECK(!ListenReset::pad_word_ok(0x00400002, 0x1E4));                // misaligned
    CHECK(ListenReset::pad_word_ok(0x02000000 - 4 - 0x1E4, 0x1E4));     // last word of RAM
    CHECK(!ListenReset::pad_word_ok(0x02000000 - 0x1E4, 0x1E4));        // past the end
    CHECK(!ListenReset::pad_word_ok(0xFFFFFFFC, 0x1E4));
    std::printf(fails ? "%d FAILED\n" : "listen_reset: all passed\n", fails);
    return fails != 0;
}
