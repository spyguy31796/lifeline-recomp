// Unit test for save-slot hotkeys (defaults, gating decisions, paths):
//   c++ -std=c++20 -I.. ../input_map.cpp ../hotkeys.cpp ../save_slots.cpp test_save_slots.cpp && ./a.out
#include "hotkeys.hpp"
#include "save_slots.hpp"
#include <cstdio>
#include <set>
#include <string>
using namespace lifeline_input;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++fails; } } while (0)
static std::string name(const Source &s) { return s.kind == Kind::Key ? "key:" + s.key : std::to_string(static_cast<int>(s.kind)) + ":" + std::to_string(s.index); }

int main() {
    std::string e;
    Map d = default_map();
    // defaults: F5 / Select+R1 save, F8 (0.5 s) / Select+L1 (1 s) load, F6 / Select+Right next slot
    CHECK(d.hk[kHkSave].size() == 2 && d.hk[kHkSave][0].keys[0].key == "F5" && d.hk[kHkSave][1].hold_ms == 500);
    CHECK(d.hk[kHkLoad].size() == 2 && d.hk[kHkLoad][0].hold_ms == 500 && d.hk[kHkLoad][1].hold_ms == 1000);
    CHECK(d.hk[kHkSlot].size() == 2 && d.hk[kHkSlot][0].keys[0].key == "F6");
    // no default chord uses Circle (push-to-talk) or a default fullscreen/quit chord
    Source circle; parse_source("b", circle, e);
    for (int h = 0; h < kHotkeyCount; ++h)
        for (const Chord &c : d.hk[h]) for (const Source &s : c.keys) CHECK(!same_source(s, circle));
    for (int h : {kHkSave, kHkLoad, kHkSlot}) {
        Source back; parse_source("back", back, e);
        CHECK(same_source(d.hk[h][1].keys[0], back));   // controller chords start with Select like the others
    }
    int h; CHECK(hotkey_from_name("HK_SAVE", h) && h == kHkSave && hotkey_from_name("hk_load", h) && hotkey_from_name("hk_slot", h));
    Map m; CHECK(parse_map("hk_save=paddle1; hk_load=none", m, e) && m.hk[kHkSave].size() == 1 && m.hk[kHkLoad].empty() && m.hk[kHkSlot].size() == 2);

    // decisions
    const unsigned SAVE = 1u << kHkSave, LOAD = 1u << kHkLoad, SLOT = 1u << kHkSlot;
    SaveSlots s("/x/saves");
    CHECK(s.on_hotkeys(0, false, false, false).action == SlotAction::None);
    CHECK(s.on_hotkeys(1u << kHkQuit, false, false, false).action == SlotAction::None);
    SlotDecision r = s.on_hotkeys(SAVE, false, false, false); CHECK(r.action == SlotAction::Save && r.slot == 1);
    r = s.on_hotkeys(LOAD, false, false, false); CHECK(r.action == SlotAction::Load && r.slot == 1);
    r = s.on_hotkeys(SAVE, true, false, false); CHECK(r.action == SlotAction::Blocked && std::string(r.why).find("Circle") != std::string::npos);
    r = s.on_hotkeys(LOAD, true, false, false); CHECK(r.action == SlotAction::Blocked);
    r = s.on_hotkeys(LOAD, false, true, false); CHECK(r.action == SlotAction::Blocked && std::string(r.why).find("voice") != std::string::npos);
    r = s.on_hotkeys(SAVE, false, true, false); CHECK(r.action == SlotAction::Blocked);
    r = s.on_hotkeys(SAVE, false, false, true); CHECK(r.action == SlotAction::Blocked);
    r = s.on_hotkeys(SAVE | LOAD, false, false, false); CHECK(r.action == SlotAction::Blocked);
    r = s.on_hotkeys(SLOT, true, true, true); CHECK(r.action == SlotAction::NextSlot && r.slot == 2);   // picking a slot is always fine
    r = s.on_hotkeys(SLOT | SAVE, false, false, false); CHECK(r.action == SlotAction::Save && r.slot == 3);
    s.on_hotkeys(SLOT, false, false, false); CHECK(s.slot() == 4);
    s.on_hotkeys(SLOT, false, false, false); CHECK(s.slot() == 1);   // wraps
    CHECK(s.state_path(2) == "/x/saves/slot2.state" && s.voice_path(2) == "/x/saves/slot2.voice" && s.backup_path() == "/x/saves/before-load.state");
    CHECK(save_slots_enabled("1") && !save_slots_enabled("0") && !save_slots_enabled(nullptr) && !save_slots_enabled("") && !save_slots_enabled("10"));
    CHECK(save_dir(nullptr) == "saves" && save_dir("/a/b//") == "/a/b" && save_dir("") == "saves");

    // chord masking: Select+R1 hides R1 from the game, Select (pressed first) keeps reaching it
    {
        HotkeyState hs; std::set<std::string> held;
        auto down = [&](const Source &x) { return held.count(name(x)) > 0; };
        Source back, rs1; parse_source("back", back, e); parse_source("rightshoulder", rs1, e);
        held = {name(back)}; hs.update(0, d, down);
        held.insert(name(rs1));
        CHECK(hs.update(10, d, down) == 0 && hs.hidden(kHkSave, 1, 1) && !hs.hidden(kHkSave, 1, 0));
        CHECK(hs.update(509, d, down) == 0);
        CHECK(hs.update(510, d, down) == SAVE);
    }
    std::printf(fails ? "%d FAILED\n" : "save slots: all passed\n", fails);
    return fails != 0;
}
