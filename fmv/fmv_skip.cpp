// FMV skip EE hook (see fmv_skip.hpp). Registered only with PS2_FMV_SKIP=1.
#include "fmv_skip.hpp"
#include "ps2/generated.hpp"
#include "ps2/memory.hpp"
#include "ps2/system.hpp"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unordered_map>

// Voice module (voice/voice_overrides.cpp): listening, a context being identified, or a fresh result.
// Weak: false when the voice module is not linked. Same rule as the save-slot / fast-forward hotkeys.
extern "C" __attribute__((weak)) bool lifeline_voice_busy();

namespace fmv {
namespace {
std::unordered_map<std::uint32_t, SkipLogic> g_players;

bool voice_busy() { return lifeline_voice_busy && lifeline_voice_busy(); }

// Emulation thread, after a state load: every player's latch is from a previous session.
void after_load() {
    for (auto &kv : g_players) kv.second.clear();
}

std::string movie_name(std::uint32_t player) {   // the path the player opened, for the log
    std::string s;
    for (std::uint32_t i = 0; i < 255; ++i) {
        const char c = static_cast<char>(ps2::ld8(player + kNameOff + i));
        if (!c) break;
        s += c;
    }
    return s;
}

bool execute(ps2::Cpu &c, std::uint32_t) {   // passive: may move 5 -> 6, then the original runs
    const std::uint32_t p = c.r[4].w[0], ra = c.r[31].w[0];
    // A state load (or any jump in emulated frames) invalidates every latch: a Start held across it must not skip.
    static std::uint64_t last_frame = 0;
    const std::uint64_t f = ps2::frames_run();
    if (last_frame && (f < last_frame || f > last_frame + kFrameGap)) after_load();
    last_frame = f;
    const std::uint32_t st = ps2::ld32(p + kStateOff);
    if (!skippable_caller(ra)) {   // in-scene slot movies: never touched
        static std::unordered_map<std::uint32_t, std::uint32_t> logged;
        if (st == kPlaying && logged[p] != ps2::ld32(p + kNameOff))
            std::fprintf(stderr, "[fmv] not skippable (in-scene slot via %08X): %s\n", ra, movie_name(p).c_str()), logged[p] = ps2::ld32(p + kNameOff);
        return false;
    }
    static std::unordered_map<std::uint32_t, std::uint32_t> announced;   // first name word per player, for the log
    if (st == kPlaying && announced[p] != ps2::ld32(p + kNameOff)) {
        announced[p] = ps2::ld32(p + kNameOff);
        std::fprintf(stderr, "[fmv] full-screen movie: %s (Start skips)\n", movie_name(p).c_str());
    }
    SkipLogic &logic = g_players[p];
    SkipLogic::Why why;
    if (logic.update(st, ps2::ld32(p + kOpenOff), ps2::pad_buttons(), voice_busy(), why)) {
        ps2::st32(p + kStateOff, kEnding);
        std::fprintf(stderr, "[fmv] skipped %s\n", movie_name(p).c_str());
    } else if (why == SkipLogic::Why::Voice) {
        std::fprintf(stderr, "[fmv] skip refused: voice command in progress\n");
    }
    return false;
}

struct Registrar {
    Registrar() {
        const char *e = std::getenv("PS2_FMV_SKIP");
        if (!e || *e != '1') return;
        ps2::register_override(kExecute, execute);
        std::fprintf(stderr, "[fmv] skip on (Start)\n");
    }
} g_registrar;
}
}

