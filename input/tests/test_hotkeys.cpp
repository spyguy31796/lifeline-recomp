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
    e.clear(); CHECK(!parse_chords("back&start@1500, , key:F11", v, e) && v.size() == 2 && e.find("empty item") != std::string::npos);
    e.clear(); CHECK(!parse_chords("key:F11,", v, e) && v.size() == 1 && e.find("empty item") != std::string::npos);
    CHECK(d.hk[kHkQuit][0].keys.size() == 2 && d.hk[kHkQuit][0].hold_ms == 500);   // Ctrl+Q needs 0.5 s
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
        HotkeyState k; held = {"key:Ctrl"}; CHECK(k.update(0, t, down) == 0); held.insert("key:Q");
        CHECK(k.update(10, t, down) == 0 && k.update(509, t, down) == 0 && k.update(510, t, down) == QUIT);
        HotkeyState f; held = {"key:F11"}; CHECK(f.update(0, t, down) == FS);
    }
    {   // SDL tick wrap-around
        HotkeyState s; held = {name(back), name(start)};
        s.update(0xFFFFFF00u, t, down); CHECK(s.update(0xFFFFFF00u + 1500u, t, down) == QUIT);
    }
    {   // regression: a held push-to-talk member stays down when the chord completes; only later members are hidden.
        // Keyboard X = circle (push-to-talk), Backspace = select; chord Backspace&X; circle pressed first.
        Map km; e.clear();
        CHECK(parse_map("circle=key:X; select=key:Backspace; hk_quit=key:Backspace&key:X@1500; hk_fullscreen=none", km, e));
        auto bits = [&](const Source &s) -> std::uint16_t {
            std::uint16_t b = 0;
            for (int tt = 0; tt < kLX; ++tt) for (const Source &x : km.src[tt]) if (same_source(x, s)) b |= static_cast<std::uint16_t>(1u << tt);
            return b;
        };
        auto frame = [&](HotkeyState &s, std::uint32_t now) {   // the buttons the game sees this frame
            s.update(now, km, down);
            std::uint16_t b = 0;
            for (const std::string &k : held) { Source x; std::string ee; parse_source(k, x, ee); b |= bits(x); }
            return static_cast<std::uint16_t>(b & ~s.mask(km, bits));
        };
        const std::uint16_t CIRCLE = 1u << kCircle, SELECT = 1u << kSelect;
        HotkeyState s; held = {"key:X"};
        bool talk_ok = true;
        for (std::uint32_t f = 0; f < 10; ++f) talk_ok = talk_ok && (frame(s, f * 16) & CIRCLE);
        held.insert("key:Backspace");                             // completes the chord while talking
        for (std::uint32_t f = 10; f < 60; ++f) {
            const std::uint16_t b = frame(s, f * 16);
            talk_ok = talk_ok && (b & CIRCLE);                    // the voice window must not end early
            CHECK(!(b & SELECT));                                 // the member pressed later is hidden
        }
        CHECK(talk_ok && s.latched(kHkQuit, 0) && !s.hidden(kHkQuit, 0, 1) && s.hidden(kHkQuit, 0, 0));
        held.erase("key:Backspace"); CHECK(frame(s, 1000) & CIRCLE);
        held.clear(); CHECK(frame(s, 1016) == 0);
        // both pressed in the same frame: neither reached the game, both hidden
        HotkeyState s2; held = {"key:X", "key:Backspace"}; CHECK(frame(s2, 0) == 0);
        // Select first (the default chords' order): Select keeps going, Start is hidden
        Map dm = default_map(); HotkeyState s3; held = {name(back)};
        auto pad = [&](const Source &x) -> std::uint16_t {
            std::uint16_t b = 0;
            for (int tt = 0; tt < kLX; ++tt) for (const Source &y : dm.src[tt]) if (same_source(y, x)) b |= static_cast<std::uint16_t>(1u << tt);
            return b;
        };
        s3.update(0, dm, down); held.insert(name(start)); s3.update(16, dm, down);
        CHECK(s3.mask(dm, pad) == (1u << kStart));
    }
    {   // raw bindings (select=joy:b6, start=joy:b7) vs the named default chord back&start: same physical buttons
        Map raw; e.clear();
        CHECK(parse_map("select=joy:b6; start=joy:b7; cross=joy:b0", raw, e));
        auto pad = [](const Source &x) {   // what SDL_GameControllerGetBindForButton reports for this pad
            Source r = x;
            if (x.kind == Kind::Button && (x.index == 4 || x.index == 6 || x.index == 0)) { r.kind = Kind::JoyButton; r.index = x.index == 4 ? 6 : x.index == 6 ? 7 : 0; }
            return r;
        };
        auto bits = [&](const Source &x) { return source_bits(raw, x, pad); };
        CHECK(bits(back) == (1u << kSelect) && bits(start) == (1u << kStart));
        Source jb7; parse_source("joy:b7", jb7, e); CHECK(bits(jb7) == (1u << kStart));
        auto ident = [](const Source &x) { return x; };
        CHECK(source_bits(raw, back, ident) == 0);   // without the pad mapping they can't be matched
        HotkeyState s; held = {name(back)};
        s.update(0, raw, down); held.insert(name(start)); s.update(16, raw, down);
        CHECK(s.latched(kHkQuit, 2) && s.mask(raw, bits) == (1u << kStart));   // Select keeps going, Start hidden
    }
    {   // fast-forward (0010): default chords, held detection, refusal / auto-release
        const Map d = default_map();
        CHECK(d.hk[kHkFastForward].size() == 2 && d.hk[kHkFastForward][0].keys[0].key == "Tab");
        CHECK(d.hk[kHkFastForward][1].keys.size() == 2 && d.hk[kHkFastForward][1].keys[0].index == 4);   // back & righttrigger
        for (const Chord &c : d.hk[kHkFastForward]) for (const Source &k : c.keys) CHECK(!(k.kind == Kind::Button && k.index == 1));   // never circle (b)
        std::set<std::string> held;
        const auto down = [&](const Source &x) { return held.count(name(x)) > 0; };
        HotkeyState s;
        CHECK(!s.held(kHkFastForward, d, down));
        held = {"key:Tab"}; CHECK(s.held(kHkFastForward, d, down));
        held = {name(d.hk[kHkFastForward][1].keys[0])}; CHECK(!s.held(kHkFastForward, d, down));   // Select alone
        held.insert(name(d.hk[kHkFastForward][1].keys[1])); CHECK(s.held(kHkFastForward, d, down));
        Map m; std::string e;
        CHECK(parse_map("hk_ff=none", m, e) && m.hk[kHkFastForward].empty());
        CHECK(parse_map("hk_ff=key:F", m, e) && m.hk[kHkFastForward].size() == 1);

        FastForward f; FastForward::Why w;
        CHECK(!f.update(false, false, false, w) && w == FastForward::Why::None);
        CHECK(f.update(true, false, false, w) && f.on());                          // held: on
        CHECK(!f.update(true, true, false, w) && w == FastForward::Why::Talk);     // circle: auto-release
        CHECK(!f.update(true, false, false, w) && w == FastForward::Why::None);    // stays off while still held
        CHECK(!f.update(false, false, false, w));                                  // let go
        CHECK(f.update(true, false, false, w));                                    // press again: on
        CHECK(!f.update(true, false, true, w) && w == FastForward::Why::Voice);    // voice listening: released
        CHECK(!f.update(false, false, false, w));
        CHECK(!f.update(true, false, true, w) && w == FastForward::Why::Voice);    // refused while busy
        CHECK(!f.update(true, false, false, w));                                   // until re-pressed
        CHECK(!f.update(false, false, false, w) && f.update(true, false, false, w));
    }
    std::printf(fails ? "%d FAILED\n" : "all hotkey tests passed\n", fails);
    return fails != 0;
}
