// Lifeline Recomp: applies PS2_INPUT_MAP to the runner's SDL GameController.
// Hooked from host/window.cpp poll() by patch 0003 through a weak symbol, so the
// runner behaves exactly as upstream when this file is not linked or the env var is unset.
#include "hotkeys.hpp"
#include "input_map.hpp"
#include "save_slots.hpp"
#include "ps2/system.hpp"   // request_state (patch 0007)
#include <SDL.h>
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>

// Voice side (voice/voice_overrides.cpp); weak so the input layer still links on its own.
extern "C" __attribute__((weak)) bool lifeline_voice_busy();
extern "C" __attribute__((weak)) const char *lifeline_voice_context();
extern "C" __attribute__((weak)) void lifeline_voice_after_load(const char *context);

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

// The raw joystick input behind a named pad button, from the controller's SDL mapping.
Source physical(SDL_GameController *pad, const Source &s) {
    if (!pad || s.kind != Kind::Button) return s;
    const SDL_GameControllerButtonBind b = SDL_GameControllerGetBindForButton(pad, static_cast<SDL_GameControllerButton>(s.index));
    Source r;
    if (b.bindType == SDL_CONTROLLER_BINDTYPE_BUTTON) { r.kind = Kind::JoyButton; r.index = b.value.button; return r; }
    if (b.bindType == SDL_CONTROLLER_BINDTYPE_HAT) { r.kind = Kind::JoyHat; r.index = b.value.hat.hat; r.hat_mask = b.value.hat.hat_mask; return r; }
    return s;
}

// PS2 buttons that this source drives, so a held chord can be kept from the game.
std::uint16_t game_bits(SDL_GameController *pad, const Map &m, const Source &s) {
    std::uint16_t bits = source_bits(m, s, [&](const Source &x) { return physical(pad, x); });
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
    static const Map gated = [] {   // save-slot chords do nothing (and hold nothing back) unless PS2_SAVE_SLOTS=1
        Map g = m;
        if (!save_slots_enabled(std::getenv("PS2_SAVE_SLOTS"))) for (int h : {kHkSave, kHkLoad, kHkSlot}) g.hk[h].clear();
        return g;
    }();
    return gated;
}

// --- Save-state slots: decided here on the host thread, done by the runner at the next vblank ---
std::atomic<bool> g_slot_busy{false};   // a request is queued or running

bool voice_busy() { return lifeline_voice_busy && lifeline_voice_busy(); }

std::string read_file(const std::string &p) {
    std::ifstream f(p); std::string s; std::getline(f, s); return s;
}

SlotResult slot_result(ps2::StateResult r) {
    return r == ps2::StateResult::Ok ? SlotResult::Ok : r == ps2::StateResult::Failed ? SlotResult::Failed : SlotResult::Vetoed;
}

void request_slot(const SaveSlots &slots, SlotAction action, int slot) {
    ps2::StateRequest r;
    r.load = action == SlotAction::Load;
    const std::string final_path = slots.state_path(slot), tmp = final_path + ".tmp", voice = slots.voice_path(slot);
    const std::string backup = slots.backup_path(), dir = slots.dir();
    if (r.load) {
        std::error_code ec;
        if (!std::filesystem::exists(final_path, ec)) { std::fprintf(stderr, "[slots] slot %d is empty\n", slot); return; }
        r.path = final_path;
        auto prev_ctx = std::make_shared<std::string>();   // voice context of the running game, for a failed load
        r.before = [backup, slot, prev_ctx] {   // re-checked on the emulation thread, then keep what's running in case the load is a mistake
            if (voice_busy()) { std::fprintf(stderr, "[slots] load slot %d skipped: voice busy\n", slot); return false; }
            // the backup is written beside it and renamed over it only when complete; if it can't be kept,
            // refuse the load so a failed load never "restores" a stale backup from an earlier session
            const std::string btmp = backup + ".tmp";
            std::error_code e;
            if (!ps2::save_state(btmp)) {
                std::filesystem::remove(btmp, e);
                std::fprintf(stderr, "[slots] load slot %d refused: could not keep the current game in %s\n", slot, backup.c_str());
                return false;
            }
            std::filesystem::rename(btmp, backup, e);
            if (e) {
                std::filesystem::remove(btmp, e);
                std::fprintf(stderr, "[slots] load slot %d refused: could not write %s\n", slot, backup.c_str());
                return false;
            }
            if (lifeline_voice_context) if (const char *c = lifeline_voice_context()) *prev_ctx = c;
            return true;
        };
        r.after = [backup, voice, slot, prev_ctx](ps2::StateResult res) {
            const LoadFollowUp f = after_load(slot_result(res));
            if (res == ps2::StateResult::Vetoed) std::fprintf(stderr, "[slots] load slot %d refused; the game keeps running\n", slot);
            if (f.restore_backup) {   // a failed load can leave the machine half restored: go back to what was running
                std::fprintf(stderr, "[slots] load slot %d failed; restoring the game from before\n", slot);
                if (!ps2::load_state(backup)) ps2::halt("save slot load failed and the previous game could not be restored");
            }
            if (f.reset_voice && lifeline_voice_after_load) lifeline_voice_after_load(f.voice_from_slot ? read_file(voice).c_str() : prev_ctx->c_str());   // Failed: the game from before
            if (res == ps2::StateResult::Ok) std::fprintf(stderr, "[slots] loaded slot %d\n", slot);
            g_slot_busy = false;
        };
    } else {
        std::error_code ec;
        std::filesystem::create_directories(dir, ec);
        r.path = tmp;   // written beside the slot, renamed over it only when complete
        r.before = [slot] {
            if (voice_busy()) { std::fprintf(stderr, "[slots] save slot %d skipped: voice busy\n", slot); return false; }
            return true;
        };
        r.after = [tmp, final_path, voice, slot](ps2::StateResult res) {
            const bool ok = res == ps2::StateResult::Ok;
            std::error_code e;
            if (ok) {
                std::filesystem::rename(tmp, final_path, e);
                if (e) std::fprintf(stderr, "[slots] cannot write %s: %s\n", final_path.c_str(), e.message().c_str());
                else {
                    const std::string vtmp = voice + ".tmp";   // voice context: same .tmp + rename as the state
                    bool vok;
                    { std::ofstream vf(vtmp, std::ios::trunc);
                      vf << (lifeline_voice_context ? lifeline_voice_context() : "") << "\n"; vf.flush(); vok = bool(vf); }
                    if (vok) std::filesystem::rename(vtmp, voice, e);
                    if (!vok || e) {
                        std::filesystem::remove(vtmp, e);
                        std::fprintf(stderr, "[slots] warning: could not write %s\n", voice.c_str());
                    }
                    std::fprintf(stderr, "[slots] saved slot %d\n", slot);
                }
            } else std::filesystem::remove(tmp, e);
            g_slot_busy = false;
        };
    }
    g_slot_busy = true;
    if (!ps2::request_state(std::move(r))) { g_slot_busy = false; std::fprintf(stderr, "[slots] busy, try again\n"); }
}
}  // namespace

// Called every frame after the pad/keys are read. Returns 1 << kHkFullscreen / 1 << kHkQuit when fired;
// save-slot hotkeys (PS2_SAVE_SLOTS=1) are handled here and queued to the runner (no runner poll() changes).
extern "C" int lifeline_hotkeys(SDL_GameController *pad, const Uint8 *keys, std::uint16_t *buttons, float *quit_progress) {
    static HotkeyState state;
    const Map &m = hotkey_map();
    const unsigned fired = state.update(SDL_GetTicks(), m, [&](const Source &s) { return pressed(pad, keys, s, false) > 0; });
    const bool talk_held = *buttons & (1u << kCircle);   // before chord masking: the game sees push-to-talk
    *buttons &= static_cast<std::uint16_t>(~state.mask(m, [&](const Source &s) { return game_bits(pad, m, s); }));
    *quit_progress = state.quit_progress();
    if (fired & (1u << kHkFullscreen)) std::fprintf(stderr, "[hotkey] fullscreen\n");
    if (fired & (1u << kHkQuit)) std::fprintf(stderr, "[hotkey] quit\n");
    static_assert((1u << kHkFullscreen) == 1 && (1u << kHkQuit) == 2, "bits match host/window.cpp kHotkey*");
    if (fired & ((1u << kHkSave) | (1u << kHkLoad) | (1u << kHkSlot))) {
        static SaveSlots slots(save_dir(std::getenv("PS2_SAVE_DIR")));
        const SlotDecision d = slots.on_hotkeys(fired, talk_held, voice_busy(), g_slot_busy.load());
        switch (d.action) {
        case SlotAction::NextSlot: std::fprintf(stderr, "[slots] slot %d selected\n", d.slot); break;
        case SlotAction::Blocked: std::fprintf(stderr, "[slots] not now: %s\n", d.why); break;
        case SlotAction::Save: case SlotAction::Load: request_slot(slots, d.action, d.slot); break;
        case SlotAction::None: break;
        }
    }
    return static_cast<int>(fired & ((1u << kHkFullscreen) | (1u << kHkQuit)));   // the runner only knows these two
}
