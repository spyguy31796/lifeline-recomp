// Lifeline Recomp: hotkey chords with hold times (SDL-free so it can be unit-tested).
#pragma once
#include "input_map.hpp"
#include <cstdint>
#include <functional>

namespace lifeline_input {

// One instance per runner. A chord latches when all its inputs are down and stays latched (its inputs
// are kept from the game) until all of them are released. It fires once per press after hold_ms;
// letting go of one input before that cancels it until everything is released.
class HotkeyState {
public:
    // Returns 1 << Hotkey for every hotkey that fired on this call.
    unsigned update(std::uint32_t now_ms, const Map &m, const std::function<bool(const Source &)> &down);
    bool latched(int hotkey, std::size_t chord) const { return chord < st_[hotkey].size() && st_[hotkey][chord].latched; }
    float quit_progress() const { return progress_; }   // 0, or 0..1 while a quit hold is under way

private:
    struct S { bool latched = false, armed = false; std::uint32_t since = 0; };
    std::vector<S> st_[kHotkeyCount];
    float progress_ = 0.0f;
};

}  // namespace lifeline_input
