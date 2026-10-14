// Unit test for hotkey parsing and chord/hold timing:
//   c++ -std=c++20 -I.. ../input_map.cpp ../hotkeys.cpp test_hotkeys.cpp && ./a.out
#include "hotkeys.hpp"
#include <cstdio>
#include <set>
#include <string>
using namespace lifeline_input;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++fails; } } while (0)

static std::string name(const Source &s) { return s.kind == Kind::Key ? "key:" + s.key : std::to_string(static_cast<int>(s.kind)) + ":" + std::to_string(s.index); }

int main() {
    // --- parser ---
    Map d = default_map();
    CHECK(d.hk[kHkFullscreen].size() == 3 && d.hk[kHkQuit].size() == 3);
    CHECK(d.hk[kHkFullscreen][0].keys.size() == 1 && d.hk[kHkFullscreen][0].keys[0].key == "F11" && d.hk[kHkFullscreen][0].hold_ms == 0);
    CHECK(d.hk[kHkFullscreen][2].keys.size() == 2 && d.hk[kHkFullscreen][2].keys[0].index == 4 && d.hk[kHkFullscreen][2].keys[1].index == 8);   // back & rightstick
    CHECK(d.hk[kHkQuit][1].keys[0].key == "Escape" && d.hk[kHkQuit][1].hold_ms == 1000);
    CHECK(d.hk[kHkQuit][2].keys.size() == 2 && d.hk[kHkQuit][2].keys[1].index == 6 && d.hk[kHkQuit][2].hold_ms == 1500);   // back & start
    std::vector<Chord> v; std::string e;
    CHECK(parse_chords(" paddle1 & paddle2 @ 800 , key:F10 ", v, e) && v.size() == 2 && v[0].keys.size() == 2 && v[0].hold_ms == 800 && v[1].keys[0].key == "F10");
    CHECK(parse_chords("none", v, e) && v.empty());
    CHECK(parse_chords("key:left alt&key:return", v, e) && v.size() == 1 && v[0].keys[1].key == "return");   // as the launcher captures it
    CHECK(parse_chords("", v, e) && v.empty());
    e.clear(); CHECK(!parse_chords("a@-1", v, e) && v.empty() && !e.empty());
    e.clear(); CHECK(!parse_chords("a@10001", v, e)); e.clear(); CHECK(!parse_chords("a@1x", v, e)); e.clear(); CHECK(!parse_chords("a@", v, e));
    e.clear(); CHECK(!parse_chords("a&&b", v, e)); e.clear(); CHECK(!parse_chords("a&b&x&y&start", v, e));
    e.clear(); CHECK(!parse_chords("righty~", v, e));
    e.clear(); CHECK(!parse_chords("zz, back&start@1500", v, e) && v.size() == 1 && v[0].hold_ms == 1500);   // good chords kept
    // in PS2_INPUT_MAP, next to the normal bindings; env string decides, unset hotkeys keep their defaults
    Map m; e.clear();
    CHECK(parse_map("circle=b; hk_quit = guide@2000; select=back", m, e) && e.empty());
    CHECK(m.hk[kHkQuit].size() == 1 && m.hk[kHkQuit][0].keys[0].index == 5 && m.hk[kHkQuit][0].hold_ms == 2000);
    CHECK(m.hk[kHkFullscreen].size() == 3);
    CHECK(parse_map("HK_FULLSCREEN=none", m, e) && m.hk[kHkFullscreen].empty());
    e.clear(); CHECK(!parse_map("hk_quit=zz; cross=x", m, e) && m.hk[kHkQuit].size() == 3 && m.src[kCross][0].index == 2);   // all bad = default
    int h; CHECK(hotkey_from_name(" hk_Quit ", h) && h == kHkQuit && !hotkey_from_name("hk_other", h));

    // --- chord / hold timing ---
    Map t = default_map();
    std::set<std::string> held;
    auto down = [&](const Source &s) { return held.count(name(s)) > 0; };
    Source back, start, rs; parse_source("back", back, e); parse_source("start", start, e); parse_source("rightstick", rs, e);
    const unsigned FS = 1u << kHkFullscreen, QUIT = 1u << kHkQuit;
    {   // quit chord: needs the full 1.5 s hold, fires once, progress grows
        HotkeyState s; held = {name(back)};
        CHECK(s.update(0, t, down) == 0 && !s.latched(kHkQuit, 2));
        held.insert(name(start));
        CHECK(s.update(100, t, down) == 0 && s.latched(kHkQuit, 2) && s.quit_progress() == 0.0f);
        CHECK(s.update(850, t, down) == 0 && s.quit_progress() > 0.49f && s.quit_progress() < 0.51f);
        CHECK(s.update(1599, t, down) == 0);
        CHECK(s.update(1600, t, down) == QUIT);
        CHECK(s.update(3000, t, down) == 0 && s.latched(kHkQuit, 2) && s.quit_progress() == 0.0f);   // once per press
        held.clear(); CHECK(s.update(3010, t, down) == 0 && !s.latched(kHkQuit, 2));
    }
    {   // a short tap or letting go of one button cancels; the rest stays masked until all are released
        HotkeyState s; held = {name(back), name(start)};
        s.update(0, t, down); held.erase(name(start));
        CHECK(s.update(500, t, down) == 0 && s.latched(kHkQuit, 2) && s.quit_progress() == 0.0f);
        held.insert(name(start)); CHECK(s.update(2500, t, down) == 0);   // re-press without full release: no quit
        held.clear(); s.update(2600, t, down);
        held = {name(back), name(start)}; s.update(3000, t, down); CHECK(s.update(4500, t, down) == QUIT);
    }
    {   // fullscreen: instant chord, once per press; Select alone does nothing
        HotkeyState s; held = {name(back)};
        CHECK(s.update(0, t, down) == 0);
        held.insert(name(rs)); CHECK(s.update(16, t, down) == FS); CHECK(s.update(32, t, down) == 0);
        held.clear(); s.update(48, t, down); held = {name(back), name(rs)}; CHECK(s.update(64, t, down) == FS);
    }
    {   // keyboard: Esc needs 1 s; Ctrl+Q is instant; F11 toggles
        HotkeyState s; held = {"key:Escape"};
        CHECK(s.update(0, t, down) == 0 && s.update(999, t, down) == 0 && s.update(1000, t, down) == QUIT);
        HotkeyState k; held = {"key:Ctrl"}; CHECK(k.update(0, t, down) == 0); held.insert("key:Q"); CHECK(k.update(10, t, down) == QUIT);
        HotkeyState f; held = {"key:F11"}; CHECK(f.update(0, t, down) == FS);
    }
    {   // SDL tick wrap-around
        HotkeyState s; held = {name(back), name(start)};
        s.update(0xFFFFFF00u, t, down); CHECK(s.update(0xFFFFFF00u + 1500u, t, down) == QUIT);
    }
    std::printf(fails ? "%d FAILED\n" : "all hotkey tests passed\n", fails);
    return fails != 0;
}
