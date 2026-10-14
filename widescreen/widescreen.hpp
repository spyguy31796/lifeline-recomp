// Native widescreen (Lifeline Recomp, PS2_WIDESCREEN=1). Hor+ 16:9: the camera's horizontal aspect factor
// (camera + 0x28; 1.0 in normal play) is scaled by 3/4 so the game projects a 4/3-wider view into the same
// 640-wide frame, and the present path (patch 0009) shows that frame at 16:9.
//
// Two hooks, both only registered with PS2_WIDESCREEN=1:
//   - Aspect setter 0x1CA208 (a0 = camera, f12 = horizontal, f13 = vertical; stores each when > 0). We scale
//     f12 on the way in so camera re-init widens exactly once.
//   - Per-frame camera update 0x1CA928 (a0 = camera). Widens cam+0x28 when it still holds a game value. A
//     value that is already 0.75 (a state saved with widescreen on, loaded in a fresh process) is left alone,
//     so it cannot become 0.5625. Needed because the setter is not called again after a state load.
#pragma once
#include <cstdint>
#include <cstring>

namespace widescreen {
constexpr std::uint32_t kAspectSetter = 0x1CA208;   // aspect setter, a0 = camera, f12 = x, f13 = y
constexpr std::uint32_t kCameraUpdate = 0x1CA928;   // per-frame camera update, a0 = camera
constexpr std::uint32_t kAspectX = 0x28;            // float the setter writes from f12
constexpr float kFactor = 0.75f;                    // (4/3) / (16/9)

inline std::uint32_t bits(float f) { std::uint32_t u; std::memcpy(&u, &f, 4); return u; }
inline float from_bits(std::uint32_t u) { float f; std::memcpy(&f, &u, 4); return f; }

// Setter's f12 after widening. Values the setter would ignore (<= 0, NaN) and anything outside a plausible
// aspect range pass through unchanged.
inline std::uint32_t widen_arg(std::uint32_t f12) {
    const float v = from_bits(f12);
    if (!(v > 0.0f) || v > 16.0f) return f12;
    return bits(v * kFactor);
}

// Per-frame: rewrite cam+0x28 when it still holds a game value. Skip when it is already our 0.75 (covers a
// widescreen-on save loaded in a fresh process) so it is never widened twice.
inline bool widen_field(std::uint32_t cur, std::uint32_t &out) {
    if (cur == bits(kFactor)) return false;
    const float native = from_bits(cur);
    if (!(native > 0.0f) || native > 16.0f) return false;
    out = bits(native * kFactor);
    return true;
}
}
