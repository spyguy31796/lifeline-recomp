// Lifeline Recomp: applies PS2_INPUT_MAP to the runner's SDL GameController.
// Hooked from host/window.cpp poll() by patch 0003 through a weak symbol, so the
// runner behaves exactly as upstream when this file is not linked or the env var is unset.
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
        if (s.invert) v = -v;
        if (s.sign) v *= s.sign;
        const bool trig = s.kind == Kind::Axis && s.index >= SDL_CONTROLLER_AXIS_TRIGGERLEFT;
        if (v <= (trig ? kTriggerThreshold : kDigitalThreshold)) return 0;
        return trigger_target ? std::max(1, v * 255 / 32767) : 255;
    }
    }
    return 0;
}

std::uint8_t to_u8(int v) { return static_cast<std::uint8_t>(std::clamp((v + 32768) >> 8, 0, 255)); }
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
        for (const Source &s : m->src[t]) { int a = axis_value(pad, s); if (s.invert) a = -a - 1; if (std::abs(a) > std::abs(v)) v = a; }
        *out[t - kLX] = to_u8(v);
    }
    return true;
}
