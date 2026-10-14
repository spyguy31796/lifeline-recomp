// Native widescreen (Lifeline Recomp, PS2_WIDESCREEN=1). Hor+ 16:9: the camera's horizontal aspect factor
// (camera + 0x28; 1.0 in normal play) is scaled by 3/4 so the game projects a 4/3-wider view into the same
// 640-wide frame, and the present path (patch 0009) shows that frame at 16:9.
#pragma once
#include <cstdint>
#include <cstring>
#include <unordered_map>

namespace widescreen {
constexpr std::uint32_t kCameraUpdate = 0x1CA928;   // per-frame camera update, a0 = camera
constexpr std::uint32_t kAspectX = 0x28;            // float, written by the aspect setter 0x1CA208
constexpr float kFactor = 0.75f;                    // (4/3) / (16/9)

inline std::uint32_t bits(float f) { std::uint32_t u; std::memcpy(&u, &f, 4); return u; }
inline float from_bits(std::uint32_t u) { float f; std::memcpy(&f, &u, 4); return f; }

// Remembers what we last wrote per camera. A value we did not write (camera init, a different camera at the
// same address, a state saved without widescreen) is the game's own and gets widened once. Returns the value
// to store, or nothing (same as current) when it is already ours.
struct Tracker {
    std::unordered_map<std::uint32_t, std::uint32_t> written;
    // Returns true and sets out when the camera's aspect must be rewritten.
    bool update(std::uint32_t cam, std::uint32_t cur, std::uint32_t &out) {
        if (auto it = written.find(cam); it != written.end() && it->second == cur) return false;
        const float native = from_bits(cur);
        if (!(native > 0.0f) || native > 16.0f) return false;   // not a valid aspect: leave the game alone
        out = bits(native * kFactor);
        written[cam] = out;
        return true;
    }
};
}
