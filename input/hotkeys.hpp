// Lifeline Recomp: hotkey chords with hold times (SDL-free so it can be unit-tested).
#pragma once
#include "input_map.hpp"
#include <cstdint>
#include <functional>

namespace lifeline_input {

// One instance per runner. A chord latches when all its inputs are down and stays latched until all of
// them are released. Inputs that were already down before the frame it latched keep reaching the game
// (they have been since they were pressed, e.g. a held push-to-talk); the ones that completed it are kept
// from the game while latched. It fires once per press after hold_ms; letting go of one input before
// that cancels it until everything is released.
class HotkeyState {
public:
    // Returns 1 << Hotkey for every hotkey that fired on this call.
    unsigned update(std::uint32_t now_ms, const Map &m, const std::function<bool(const Source &)> &down);
    bool latched(int hotkey, std::size_t chord) const { return chord < st_[hotkey].size() && st_[hotkey][chord].latched; }
    // Input `key` of a latched chord is kept from the game (it was not down before the chord completed).
    bool hidden(int hotkey, std::size_t chord, std::size_t key) const {
        return latched(hotkey, chord) && key < st_[hotkey][chord].hide.size() && st_[hotkey][chord].hide[key];
    }
    // PS2 buttons to clear this frame; game_bits(src) = buttons that src drives.
    std::uint16_t mask(const Map &m, const std::function<std::uint16_t(const Source &)> &game_bits) const;
    float quit_progress() const { return progress_; }   // 0, or 0..1 while a quit hold is under way
    // Some chord of `hotkey` has every input down right now (for held hotkeys such as hk_ff).
    bool held(int hotkey, const Map &m, const std::function<bool(const Source &)> &down) const;

private:
    struct S { bool latched = false, armed = false; std::uint32_t since = 0; std::vector<bool> prev, hide; };
    std::vector<S> st_[kHotkeyCount];
    float progress_ = 0.0f;
};

// Fast-forward gate (Lifeline Recomp 0010). On while the hk_ff chord is held, unless push-to-talk (circle)
// is down or the voice recognizer is listening / has a result pending: then it is refused, or released if
// already on, and stays off until the chord is let go and pressed again.
class FastForward {
public:
    enum class Why { None, Talk, Voice };
    // Returns whether FF is on this frame; why = reason for a refusal/auto-release on this frame.
    bool update(bool chord_held, bool talk_held, bool voice_busy, Why &why) {
        why = Why::None;
        if (!chord_held) { blocked_ = false; return on_ = false; }
        if (blocked_) return on_ = false;
        if (talk_held || voice_busy) { why = talk_held ? Why::Talk : Why::Voice; blocked_ = true; return on_ = false; }
        return on_ = true;
    }
    bool on() const { return on_; }
private:
    bool on_ = false, blocked_ = false;
};

}  // namespace lifeline_input
