// Native widescreen EE hook (see widescreen.hpp). Registered only with PS2_WIDESCREEN=1; with it off the
// translated code runs untouched.
#include "widescreen.hpp"
#include "ps2/generated.hpp"
#include "ps2/memory.hpp"
#include <cstdio>
#include <cstdlib>

namespace widescreen {
namespace {
Tracker g_tracker;

bool camera_update(ps2::Cpu &c, std::uint32_t) {   // passive: fix the aspect, then run the original
    const std::uint32_t cam = c.r[4].w[0], a = cam + kAspectX;
    if (std::uint32_t v; g_tracker.update(cam, ps2::ld32(a), v)) ps2::st32(a, v);
    return false;
}

struct Registrar {
    Registrar() {
        const char *ws = std::getenv("PS2_WIDESCREEN");
        if (!ws || *ws != '1') return;
        ps2::register_override(kCameraUpdate, camera_update);
        std::fprintf(stderr, "[widescreen] 16:9 hor+ on\n");
    }
} g_registrar;
}
}
