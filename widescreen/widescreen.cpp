// Native widescreen EE hooks (see widescreen.hpp). Registered only with PS2_WIDESCREEN=1; with it off the
// translated code still hits an ee_override lookup at 0x1CA928 (and at the setter when that runs) but nothing
// is registered, so the original runs.
#include "widescreen.hpp"
#include "ps2/generated.hpp"
#include "ps2/memory.hpp"
#include <cstdio>
#include <cstdlib>

namespace widescreen {
namespace {
bool aspect_setter(ps2::Cpu &c, std::uint32_t) {   // passive: widen f12, then run the original
    c.f[12] = widen_arg(c.f[12]);
    return false;
}

bool camera_update(ps2::Cpu &c, std::uint32_t) {   // passive: fix a leftover game value, then run the original
    const std::uint32_t a = c.r[4].w[0] + kAspectX;
    if (std::uint32_t v; widen_field(ps2::ld32(a), v)) ps2::st32(a, v);
    return false;
}

struct Registrar {
    Registrar() {
        const char *ws = std::getenv("PS2_WIDESCREEN");
        if (!ws || *ws != '1') return;
        ps2::register_override(kAspectSetter, aspect_setter);
        ps2::register_override(kCameraUpdate, camera_update);
        std::fprintf(stderr, "[widescreen] 16:9 hor+ on\n");
    }
} g_registrar;
}
}
