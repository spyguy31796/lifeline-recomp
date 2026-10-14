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

private:
    struct S { bool latched = false, armed = false; std::uint32_t since = 0; std::vector<bool> prev, hide; };
    std::vector<S> st_[kHotkeyCount];
    float progress_ = 0.0f;
};

}  // namespace lifeline_input
