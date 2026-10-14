// Lifeline Recomp: hotkey chord state machine (see hotkeys.hpp).
#include "hotkeys.hpp"
#include <algorithm>

namespace lifeline_input {

unsigned HotkeyState::update(std::uint32_t now, const Map &m, const std::function<bool(const Source &)> &down) {
    unsigned fired = 0;
    progress_ = 0.0f;
    for (int h = 0; h < kHotkeyCount; ++h) {
        st_[h].resize(m.hk[h].size());
        for (std::size_t i = 0; i < m.hk[h].size(); ++i) {
            const Chord &c = m.hk[h][i];
            S &s = st_[h][i];
            bool all = !c.keys.empty(), any = false;
            std::vector<bool> d(c.keys.size());
            for (std::size_t k = 0; k < c.keys.size(); ++k) { d[k] = down(c.keys[k]); all = all && d[k]; any = any || d[k]; }
            std::vector<bool> prev = d;
            s.prev.swap(prev);   // prev = state on the previous update
            prev.resize(c.keys.size());
            if (!s.latched) {
                if (!all) continue;
                s.latched = s.armed = true;
                s.since = now;
                s.hide.assign(c.keys.size(), false);
                bool earlier = false;   // something was already down: it keeps reaching the game
                for (std::size_t k = 0; k < c.keys.size(); ++k) earlier = earlier || prev[k];
                for (std::size_t k = 0; k < c.keys.size(); ++k) s.hide[k] = !(earlier && prev[k]);
            } else if (!any) {
                s.latched = s.armed = false;
                continue;
            }
            if (!s.armed) continue;
            if (!all) { s.armed = false; continue; }
            const std::uint32_t held = now - s.since;
            if (held >= static_cast<std::uint32_t>(c.hold_ms)) { fired |= 1u << h; s.armed = false; }
            else if (h == kHkQuit) progress_ = std::max(progress_, static_cast<float>(held) / static_cast<float>(c.hold_ms));
        }
    }
    return fired;
}

std::uint16_t HotkeyState::mask(const Map &m, const std::function<std::uint16_t(const Source &)> &game_bits) const {
    std::uint16_t bits = 0, keep = 0;
    for (int h = 0; h < kHotkeyCount; ++h)
        for (std::size_t i = 0; i < m.hk[h].size(); ++i)
            for (std::size_t k = 0; k < m.hk[h][i].keys.size(); ++k)
                if (hidden(h, i, k)) bits |= game_bits(m.hk[h][i].keys[k]);
                else if (latched(h, i)) keep |= game_bits(m.hk[h][i].keys[k]);
    return static_cast<std::uint16_t>(bits & ~keep);   // a button held through any chord is never cut off
}

}  // namespace lifeline_input
