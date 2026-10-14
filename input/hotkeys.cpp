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
            for (const Source &k : c.keys) { const bool d = down(k); all = all && d; any = any || d; }
            if (!s.latched) {
                if (!all) continue;
                s.latched = s.armed = true;
                s.since = now;
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

}  // namespace lifeline_input
