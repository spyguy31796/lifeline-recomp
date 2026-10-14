// Lifeline Recomp: applies PS2_INPUT_MAP to the runner's SDL GameController.
// Hooked from host/window.cpp poll() by patch 0003 through a weak symbol, so the
// runner behaves exactly as upstream when this file is not linked or the env var is unset.
#include "hotkeys.hpp"
#include "input_map.hpp"
#include <SDL.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>

using namespace lifeline_input;

namespace {
constexpr int kDigitalThreshold = 16000, kTriggerThreshold = 2000;

const Map *map() {
    static Map m;
    static const bool on = [] {
        const char *spec = std::getenv("PS2_INPUT_MAP");
        if (!spec || !*spec) return false;
        std::string err;
        if (!parse_map(spec, m, err)) std::fprintf(stderr, "PS2_INPUT_MAP: %s(other entries applied)\n", err.c_str());
        return true;
    }();
    return on ? &m : nullptr;
}

// "Ctrl", "Shift", "Alt", "GUI" mean either side; returns the left scancode (right = left + 4) or 0.
int modifier(const std::string &k) {
    if (SDL_strcasecmp(k.c_str(), "ctrl") == 0) return SDL_SCANCODE_LCTRL;
    if (SDL_strcasecmp(k.c_str(), "shift") == 0) return SDL_SCANCODE_LSHIFT;
    if (SDL_strcasecmp(k.c_str(), "alt") == 0) return SDL_SCANCODE_LALT;
    if (SDL_strcasecmp(k.c_str(), "gui") == 0) return SDL_SCANCODE_LGUI;
    return 0;
}

int axis_value(SDL_GameController *pad, const Source &s) {   // -32768..32767, 0 if unavailable
    if (!pad) return 0;
    if (s.kind == Kind::Axis) return SDL_GameControllerGetAxis(pad, static_cast<SDL_GameControllerAxis>(s.index));
    SDL_Joystick *j = SDL_GameControllerGetJoystick(pad);
    return j && s.index < SDL_JoystickNumAxes(j) ? SDL_JoystickGetAxis(j, s.index) : 0;
}

// Returns pressure 1..255 when pressed (255 for plain buttons), 0 when not.
int pressed(SDL_GameController *pad, const Uint8 *keys, const Source &s, bool trigger_target) {
    switch (s.kind) {
    case Kind::Button: return pad && SDL_GameControllerGetButton(pad, static_cast<SDL_GameControllerButton>(s.index)) ? 255 : 0;
    case Kind::Key: {
        static_assert(sizeof(SDL_Scancode) <= sizeof(int));
        if (const int mod = modifier(s.key)) return keys && (keys[mod] || keys[mod + 4]) ? 255 : 0;   // left or right
        const SDL_Scancode sc = SDL_GetScancodeFromName(s.key.c_str());
        return sc != SDL_SCANCODE_UNKNOWN && keys && keys[sc] ? 255 : 0;
    }
    case Kind::JoyButton: {
        SDL_Joystick *j = pad ? SDL_GameControllerGetJoystick(pad) : nullptr;
        return j && s.index < SDL_JoystickNumButtons(j) && SDL_JoystickGetButton(j, s.index) ? 255 : 0;
    }
    case Kind::JoyHat: {
        SDL_Joystick *j = pad ? SDL_GameControllerGetJoystick(pad) : nullptr;
        return j && s.index < SDL_JoystickNumHats(j) && (SDL_JoystickGetHat(j, s.index) & s.hat_mask) ? 255 : 0;
    }
    case Kind::Axis: case Kind::JoyAxis: {
        int v = axis_value(pad, s);
        if (s.invert) v = invert_axis(v);
        if (s.sign) v *= s.sign;
        const bool trig = s.kind == Kind::Axis && s.index >= SDL_CONTROLLER_AXIS_TRIGGERLEFT;
        if (v <= (trig ? kTriggerThreshold : kDigitalThreshold)) return 0;
        return trigger_target ? std::max(1, v * 255 / 32767) : 255;
    }
    }
    return 0;
}

}  // namespace

// Called every frame. Keyboard defaults are already in *buttons; we add the pad (and key:) bindings.
extern "C" bool lifeline_input_remap(SDL_GameController *pad, const Uint8 *keys, std::uint16_t *buttons,
                                     std::uint8_t *l2, std::uint8_t *r2, std::uint8_t *lx, std::uint8_t *ly,
                                     std::uint8_t *rx, std::uint8_t *ry) {
    const Map *m = map();
    if (!m) return false;
    for (int t = 0; t < kLX; ++t) {
        int best = 0;
        for (const Source &s : m->src[t]) best = std::max(best, pressed(pad, keys, s, t == kL2 || t == kR2));
        if (!best || (*buttons & (1u << t))) continue;
        *buttons |= static_cast<std::uint16_t>(1u << t);
        if (t == kL2 && best < 255) *l2 = static_cast<std::uint8_t>(best);
        if (t == kR2 && best < 255) *r2 = static_cast<std::uint8_t>(best);
    }
    std::uint8_t *out[] = {lx, ly, rx, ry};
    for (int t = kLX; t < kTargetCount; ++t) {
        if (*out[t - kLX] != 0x80 || m->src[t].empty()) continue;   // keyboard arrows already set the left stick
        int v = 0;
        for (const Source &s : m->src[t]) { int a = axis_value(pad, s); if (s.invert) a = invert_axis(a); if (std::abs(a) > std::abs(v)) v = a; }
        *out[t - kLX] = axis_to_u8(v, false);
    }
    return true;
}

namespace {
// The runner's built-in keyboard table (host/window.cpp kKeys): keys reach the game even without a map.
struct BuiltinKey { const char *name; int target; };
constexpr BuiltinKey kBuiltinKeys[] = {
    {"Up", kUp}, {"Down", kDown}, {"Left", kLeft}, {"Right", kRight}, {"Z", kCross}, {"X", kCircle}, {"A", kSquare},
    {"S", kTriangle}, {"Q", kL1}, {"W", kR1}, {"1", kL2}, {"2", kR2}, {"Return", kStart}, {"Backspace", kSelect},
};

// PS2 buttons that this source drives, so a held chord can be kept from the game.
std::uint16_t game_bits(const Map &m, const Source &s) {
    std::uint16_t bits = 0;
    for (int t = 0; t < kLX; ++t)
        for (const Source &x : m.src[t])
            if (same_source(x, s)) bits |= static_cast<std::uint16_t>(1u << t);
    if (s.kind == Kind::Key)
        for (const BuiltinKey &k : kBuiltinKeys)
            if (SDL_GetScancodeFromName(k.name) == SDL_GetScancodeFromName(s.key.c_str())) bits |= static_cast<std::uint16_t>(1u << k.target);
    return bits;
}

const Map &hotkey_map() {
    static const Map m = [] {
        const char *spec = std::getenv("PS2_INPUT_MAP");
        if (!spec || !*spec) return default_map();   // no map: built-in pad table + default hotkeys
        Map x; std::string err; parse_map(spec, x, err);   // errors are reported by map()
        return x;
    }();
    return m;
}
}  // namespace

// Called every frame after the pad/keys are read. Returns 1 << kHkFullscreen / 1 << kHkQuit when fired.
extern "C" int lifeline_hotkeys(SDL_GameController *pad, const Uint8 *keys, std::uint16_t *buttons, float *quit_progress) {
    static HotkeyState state;
    const Map &m = hotkey_map();
    const unsigned fired = state.update(SDL_GetTicks(), m, [&](const Source &s) { return pressed(pad, keys, s, false) > 0; });
    std::uint16_t mask = 0;
    for (int h = 0; h < kHotkeyCount; ++h)
        for (std::size_t i = 0; i < m.hk[h].size(); ++i)
            if (state.latched(h, i))
                for (const Source &s : m.hk[h][i].keys) mask |= game_bits(m, s);
    *buttons &= static_cast<std::uint16_t>(~mask);
    *quit_progress = state.quit_progress();
    if (fired & (1u << kHkFullscreen)) std::fprintf(stderr, "[hotkey] fullscreen\n");
    if (fired & (1u << kHkQuit)) std::fprintf(stderr, "[hotkey] quit\n");
    static_assert((1u << kHkFullscreen) == 1 && (1u << kHkQuit) == 2, "bits match host/window.cpp kHotkey*");
    return static_cast<int>(fired);
}
