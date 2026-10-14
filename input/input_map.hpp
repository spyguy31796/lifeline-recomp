// Lifeline Recomp: controller remapping layer (our code, MIT).
// Parses PS2_INPUT_MAP ("target=src[,src...];target=...") into a table that
// input_map_sdl.cpp applies to the SDL GameController each frame. The same string carries the
// hotkeys: "hk_fullscreen=key:F11, back&rightstick; hk_quit=back&start@1500" ('&' = chord, '@' = hold ms).
#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace lifeline_input {

// PS2 pad targets. Digital ones use the DualShock bit layout of the host runner.
enum Target : int {
    kSelect, kL3, kR3, kStart, kUp, kRight, kDown, kLeft,
    kL2, kR2, kL1, kR1, kTriangle, kCircle, kCross, kSquare,  // bit = 1 << index
    kLX, kLY, kRX, kRY,                                       // analog sticks
    kTargetCount
};

enum class Kind : std::uint8_t { Button, Axis, JoyButton, JoyAxis, JoyHat, Key };

struct Source {
    Kind kind{};
    int index = 0;      // SDL_GameControllerButton / SDL_GameControllerAxis / joystick index / hat index
    int sign = 0;       // axis: +1 / -1 for a direction, 0 = whole axis (triggers, analog targets)
    bool invert = false;// analog targets: '~' suffix
    int hat_mask = 0;   // SDL_HAT_* bits
    std::string key;    // Key: SDL scancode name, resolved at run time
};

// kHkSave / kHkLoad / kHkSlot: save-state slots (only active with PS2_SAVE_SLOTS=1, see save_slots.hpp).
enum Hotkey : int { kHkFullscreen, kHkQuit, kHkSave, kHkLoad, kHkSlot, kHkFastForward, kHotkeyCount };
extern const char *const kHotkeyNames[kHotkeyCount];      // "hk_fullscreen", "hk_quit", "hk_save", "hk_load", "hk_slot", "hk_ff" (held)
extern const char *const kHotkeyDefaults[kHotkeyCount];
constexpr int kMaxHoldMs = 10000, kMaxChordKeys = 4;

struct Chord {                // every source held together; fires after hold_ms
    std::vector<Source> keys;
    int hold_ms = 0;
};

struct Map {
    bool active = false;
    bool bound[kTargetCount] = {};           // target mentioned in the map
    std::vector<Source> src[kTargetCount];   // empty + bound = unbound ("none")
    std::vector<Chord> hk[kHotkeyCount];     // defaults unless the map sets hk_*; empty = disabled
};

bool target_from_name(const std::string &n, int &out);
bool parse_source(const std::string &s, Source &out, std::string &err);
// Unmentioned targets keep their default binding; returns false and fills err on any bad entry
// (bad entries are skipped, the rest still applies).
bool parse_map(const std::string &spec, Map &out, std::string &err);
bool hotkey_from_name(const std::string &n, int &out);
// "chord[@ms], chord..." where chord = "src&src..."; "none" or "" = no chords.
bool parse_chords(const std::string &spec, std::vector<Chord> &out, std::string &err);
bool same_source(const Source &a, const Source &b);
// PS2 buttons (bit per digital target) that source s drives in map m. `physical` rewrites a source to the
// raw joystick input it reads (a named button -> joy:bN / joy:hN.dir via the pad's SDL mapping), so a
// raw binding and the named button for the same physical button compare equal. Identity if unknown.
std::uint16_t source_bits(const Map &m, const Source &s, const std::function<Source(const Source &)> &physical);
Map default_map();
// SDL axis value (-32768..32767) -> PS2 stick byte; 0 maps to 0x80 with or without invert.
int invert_axis(int v);
std::uint8_t axis_to_u8(int v, bool invert);

}  // namespace lifeline_input
