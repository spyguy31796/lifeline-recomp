// Lifeline voice replacement: EE function overrides for CKclAsr (see VOICE-MAP.md).
// Environment:
//   PS2_VOICE_OFF=1          disable all overrides (original VoCon path runs)
//   PS2_VOICE_ASSETS=<dir>   directory tree of the user's own extracted .ctx/.wrd files, used only
//                            to name the context a SetContext command loads (contents are hashed, never stored)
//   PS2_VOICE_CONTEXT=<stem>  preset the active context (for runs resumed with --load-state)
//   PS2_VOICE_INJECT=<file>  debug injection, lines "FRAME [ctx=stem,...] phrase[|phrase...] [@confidence]"
//   PS2_VOICE_VOSK_MODEL=<dir> enable the Vosk backend with this model (PS2_VOICE_VOSK_LIB=<libvosk.so>)
//   PS2_VOICE_WAV_SCHEDULE / PS2_VOICE_WAV_DIR  file audio instead of the SDL microphone (see audio_source.hpp)
//   PS2_VOICE_DEBUG=1, PS2_VOICE_LOG=<file>    per-recognition log (default ./voice.log)
#include "lifeline_addrs.hpp"
#include "recognizer.hpp"
#include "result_writer.hpp"
#include "debug_log.hpp"
#include "vgp.hpp"

#include "ps2/generated.hpp"
#include "ps2/memory.hpp"
#include "ps2/system.hpp"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace voice {
namespace {
using namespace addr;

std::uint32_t phys(std::uint32_t a) { return a & 0x0FFFFFFFu; } // strip the 0x20000000/0x30000000 uncached mirrors
std::uint64_t now() { return ps2::frame_count(); }

std::uint64_t fnv(const std::uint8_t *p, std::size_t n) {
    std::uint64_t h = 1469598103934665603ull;
    for (std::size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}
std::uint64_t guest_hash(std::uint32_t a, std::uint32_t n) {
    std::uint64_t h = 1469598103934665603ull;
    for (std::uint32_t i = 0; i < n; ++i) { h ^= ps2::ld8(a + i); h *= 1099511628211ull; }
    return h;
}

struct State {
    bool loaded = false;
    std::map<std::uint64_t, std::string> names; // content hash -> "archive/file"
    struct Inject { std::uint64_t frame; std::vector<std::string> words; std::uint16_t conf; bool done; std::vector<std::string> ctx; };
    std::vector<Inject> injects;
    std::uint32_t vgp_base = 0;
    std::optional<Vgp> vgp;
    std::unique_ptr<Recognizer> rec;
    std::string vocab_from;
    std::string context;
    std::uint32_t pend_ctx = 0, pend_wrd = 0;
    std::uint64_t pend_since = 0;
} g;

// Read by the save-slot hotkeys on the host thread (lifeline_voice_busy below).
std::atomic<bool> g_listening{false}, g_identifying{false};
std::atomic<std::int64_t> g_result_ms{0};   // steady clock ms of the last result handed to the game
std::int64_t steady_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

void vocab_for_context();
void load_once() {
    if (g.loaded) return;
    g.loaded = true;
    g.rec = make_vosk_recognizer();
    if (!g.rec) g.rec = make_null_recognizer();
    if (const char *dir = std::getenv("PS2_VOICE_ASSETS")) {
        std::error_code ec;
        for (const auto &e : std::filesystem::recursive_directory_iterator(dir, ec)) {
            const auto ext = e.path().extension().string();
            if (ext != ".ctx" && ext != ".wrd") continue;
            std::ifstream f(e.path(), std::ios::binary);
            std::vector<std::uint8_t> b((std::istreambuf_iterator<char>(f)), {});
            g.names.emplace(fnv(b.data(), b.size()), e.path().parent_path().filename().string() + "/" + e.path().filename().string());
        }
        std::fprintf(stderr, "[voice] indexed %zu context files from PS2_VOICE_ASSETS\n", g.names.size());
    }
    if (const char *path = std::getenv("PS2_VOICE_INJECT")) {
        std::ifstream f(path);
        for (std::string line; std::getline(f, line);) {
            if (line.empty() || line[0] == '#') continue;
            std::istringstream in(line);
            State::Inject j{0, {}, 9000, false, {}};
            in >> j.frame;
            std::string rest; std::getline(in, rest);
            if (auto at = rest.rfind('@'); at != std::string::npos) { j.conf = static_cast<std::uint16_t>(std::stoi(rest.substr(at + 1))); rest.resize(at); }
            while (!rest.empty() && rest.front() == ' ') rest.erase(0, 1);
            if (rest.rfind("ctx=", 0) == 0) {
                const auto sp = rest.find(' ');
                std::stringstream cs(rest.substr(4, sp - 4));
                for (std::string t; std::getline(cs, t, ',');) j.ctx.push_back(t);
                rest = sp == std::string::npos ? "" : rest.substr(sp + 1);
            }
            while (!rest.empty() && rest.back() == ' ') rest.pop_back();
            std::stringstream ws(rest);
            for (std::string w; std::getline(ws, w, '|');) if (!w.empty()) j.words.push_back(w);
            g.injects.push_back(j);
        }
        std::fprintf(stderr, "[voice] %zu injections queued\n", g.injects.size());
    }
    // After --load-state the SetContext that set up the current context is not replayed; let the user name it.
    if (const char *ctx = std::getenv("PS2_VOICE_CONTEXT")) {
        g.context = std::string(ctx) + ".wrd";
        std::fprintf(stderr, "[voice] context preset to %s\n", ctx);
        vocab_for_context();
    }
}

// Until the matcher hook sees the guest VGP, take the phrase table from the user's own extracted
// <archive>/<stem>.vgp for the active context (context names come from PS2_VOICE_ASSETS).
void vocab_for_context() {
    const char *dir = std::getenv("PS2_VOICE_ASSETS");
    if (!dir || g.context.size() < 5 || g.context == g.vocab_from) return;
    g.vocab_from = g.context;
    std::string stem = g.context.substr(0, g.context.size() - 4);  // "<archive>/<name>"
    std::string path = std::string(dir) + "/" + stem + ".vgp";
    std::ifstream f(path, std::ios::binary);
    // Room command contexts (ai_<room>) have no phrase table of their own; the game's matcher uses the
    // room's os_<room>.vgp from the same archive (verb / object / chat slot phrases).
    if (const auto slash = stem.rfind('/'); !f && stem.compare(slash + 1, 3, "ai_") == 0) {
        path = std::string(dir) + "/" + stem.substr(0, slash + 1) + "os_" + stem.substr(slash + 4) + ".vgp";
        f.open(path, std::ios::binary);
    }
    if (!f) { std::fprintf(stderr, "[voice] no %s for vocabulary\n", path.c_str()); return; }
    std::vector<std::uint8_t> b((std::istreambuf_iterator<char>(f)), {});
    auto v = parse_vgp_bytes(b);
    if (!v) return;
    std::vector<std::string> p; std::vector<int> cls;
    for (const auto &e : v->entries) { p.push_back(e.phrase); cls.push_back(e.clsid); }
    g.rec->set_vocabulary(p, cls);
    if (!g.vgp) g.vgp = std::move(v);
    std::fprintf(stderr, "[voice] f%llu vocabulary for %s: %zu phrases\n", (unsigned long long)now(), g.context.c_str(), p.size());
}

const char *name_of(std::uint32_t a, std::uint32_t n) {
    const auto it = g.names.find(guest_hash(a, n));
    return it == g.names.end() ? "?" : it->second.c_str();
}

// The buffers named by SetContext may be filled after the command is posted, so retry until they hold data.
void try_identify() {
    if (!g.pend_wrd) return;
    const std::uint32_t ctx_len = ps2::ld32(g.pend_ctx + 4), wrd_len = ps2::ld32(g.pend_wrd);
    if (!ctx_len || !wrd_len || ctx_len > 0x200000 || wrd_len > 0x200000) return;
    const char *cn = name_of(g.pend_ctx, ctx_len), *wn = name_of(g.pend_wrd, wrd_len);
    g.context = wn;
    std::fprintf(stderr, "[voice] f%llu context identified (posted f%llu): ctx=%s (%u B) wrd=%s (%u B, %u words)\n", (unsigned long long)now(),
                 (unsigned long long)g.pend_since, cn, ctx_len, wn, wrd_len, ps2::ld32(g.pend_wrd + 4));
    g.pend_ctx = g.pend_wrd = 0;
    g_identifying = false;
    g.vgp.reset(); g.vgp_base = 0;
    vocab_for_context();
}

bool ret(ps2::Cpu &c, std::uint32_t v0) {
    ps2::set32(c.r[2], v0);
    c.pc = c.r[31].w[0];
    return true;
}

bool try_inject();

// Push-to-talk released: decode the captured audio and hand an in-grammar result to the game.
bool deliver_recognition() {
    g.rec->stop();
    Recognition r;
    if (!g.rec->poll(r)) return false;
    const bool accept = !r.words.empty();
    // Speech that matched nothing (off-grammar or [unk]) is delivered as a VoCon-style rejection: no words,
    // confidence 0, result id -1. GetStatus then reports 4 and CCanesVoice plays its normal "BAD!" feedback
    // (verified in the tutorial). Only an empty decode (silence / accidental tap) leaves the engine idle.
    const bool heard = !r.raw.empty();
    if (accept) write_result(r.words, r.confidence, 0);
    else if (heard) write_result({}, 0, -1);
    if (accept || heard) g_result_ms = steady_ms();
    std::string joined;
    for (const auto &w : r.words) joined += (joined.empty() ? "" : " | ") + w;
    char line[1024];
    std::snprintf(line, sizeof line, "f%llu ctx=%s clip=%s raw=\"%s\" match=\"%s\" conf=%u threshold=%u %s(%s) latency_ms=%.1f audio_ms=%.0f",
                  (unsigned long long)now(), g.context.c_str(), r.clip.empty() ? "-" : r.clip.c_str(), r.raw.c_str(), accept ? joined.c_str() : "",
                  r.confidence, ps2::ld32(kThreshold), accept ? "ACCEPT" : heard ? "REJECT->game" : "SILENCE", r.how.c_str(), r.latency_ms, r.audio_ms);
    std::fprintf(stderr, "[voice] %s\n", line);
    debug_log(line);
    return accept || heard;
}

bool init_engine(ps2::Cpu &c, std::uint32_t) {
    load_once();
    ps2::st32(kThreshold, c.r[6].w[0]);
    write_no_result();
    std::fprintf(stderr, "[voice] f%llu InitEngine stubbed (lang %08X threshold %u threads %u); VoCon not started\n",
                 (unsigned long long)now(), c.r[5].w[0], c.r[6].w[0], c.r[7].w[0]);
    return ret(c, 0);
}

bool close_engine(ps2::Cpu &c, std::uint32_t) {
    std::fprintf(stderr, "[voice] f%llu Close stubbed\n", (unsigned long long)now());
    return ret(c, 1);
}

bool post_message(ps2::Cpu &c, std::uint32_t) {
    load_once();
    try_identify();
    const std::uint32_t m = c.r[4].w[0];
    const std::uint32_t type = ps2::ld32(m), p1 = ps2::ld32(m + 4), p2 = ps2::ld32(m + 8), p3 = ps2::ld32(m + 12);
    if (type != 3) std::fprintf(stderr, "[voice] f%llu cmd %u p1 %08X p2 %08X p3 %08X ra %08X\n", (unsigned long long)now(), type, p1, p2, p3, c.r[31].w[0]);
    switch (type) {
    case 1: ps2::st32(kState, 1); g.rec->start(); g_listening = true; break;
    case 2: // stop listening (push-to-talk released): deliver an injected result, else go idle
        if (ps2::ld32(kState) == 1 && !deliver_recognition() && !try_inject()) ps2::st32(kState, 2);
        g_listening = false;
        break;
    case 8: ps2::st32(kThreshold, p1); break;
    case 5:
        g.pend_ctx = phys(p1); g.pend_wrd = phys(p2); g.pend_since = now(); g.context = "?"; g_identifying = true;
        std::fprintf(stderr, "[voice] f%llu SetContext posted ctx@%08X wrd@%08X\n", (unsigned long long)now(), g.pend_ctx, g.pend_wrd);
        try_identify();
        break;
    default: break;
    }
    return ret(c, 1);
}

// Passive: capture the VGP table the game's matcher uses, then let the original run.
bool matcher(ps2::Cpu &c, std::uint32_t) {
    const std::uint32_t base = ps2::ld32(c.r[4].w[0]);
    if (base != g.vgp_base) {
        g.vgp_base = base;
        g.vgp = parse_vgp(base);
        std::fprintf(stderr, "[voice] f%llu VGP at %08X: %s, %zu phrases\n", (unsigned long long)now(), base, g.vgp ? "ok" : "not a VGP",
                     g.vgp ? g.vgp->entries.size() : 0);
        if (g.vgp) {
            std::vector<std::string> p; std::vector<int> cls;
            for (const auto &e : g.vgp->entries) { p.push_back(e.phrase); cls.push_back(e.clsid); }
            g.rec->set_vocabulary(p, cls);
        }
    }
    std::fprintf(stderr, "[voice] f%llu matcher called with %u words\n", (unsigned long long)now(), c.r[6].w[0]);
    return false;
}

// Deliver the next queued injection whose frame and context match. Returns true if a result was written.
bool try_inject() {
    for (auto &j : g.injects) {
        if (j.done || now() < j.frame) continue;
        if (!j.ctx.empty()) {
            bool ok = false;
            for (const auto &t : j.ctx) ok |= g.context.find(t + ".wrd") != std::string::npos;
            if (!ok) continue;
        }
        j.done = true;
        for (const auto &w : j.words)
            if (g.vgp && !g.vgp->find(w)) std::fprintf(stderr, "[voice] warning: '%s' is not in the current VGP\n", w.c_str());
        write_result(j.words, j.conf, 0);
        g_result_ms = steady_ms();
        std::fprintf(stderr, "[voice] f%llu injected '%s'%s (%zu words, conf %u, context %s)\n", (unsigned long long)now(), j.words.empty() ? "" : j.words[0].c_str(),
                     j.words.size() > 1 ? "..." : "", j.words.size(), j.conf, g.context.c_str());
        return true;
    }
    return false;
}

// Passive: log state changes and deliver recognizer results before the game reads status.
bool get_status(ps2::Cpu &, std::uint32_t) {
    load_once();
    try_identify();
    static std::uint32_t last = 0xFFFFFFFFu;
    if (const std::uint32_t st = ps2::ld32(kState); st != last) {
        std::fprintf(stderr, "[voice] f%llu state %u -> %u\n", (unsigned long long)now(), last, st);
        last = st;
    }
    return false;
}

bool g_registered = false;

struct Registrar {
    Registrar() {
        if (const char *off = std::getenv("PS2_VOICE_OFF"); off && *off == '1') return;
        ps2::register_override(kInitEngine, init_engine);
        ps2::register_override(kClose, close_engine);
        ps2::register_override(kPostMessage, post_message);
        ps2::register_override(kMatcher, matcher);
        ps2::register_override(kGetStatus, get_status);
        g_registered = true;
    }
} g_registrar;

}

// --- Save-state slots (input/save_slots.hpp) -------------------------------------------------------------
// Busy = a save or load now would cut a voice exchange in half: listening (push-to-talk down), a SetContext
// not identified yet, or a result handed to the game in the last 1.5 s that it may not have read yet.
constexpr std::int64_t kResultGraceMs = 1500;
bool busy() {
    if (!g_registered) return false;
    return g_listening || g_identifying || steady_ms() - g_result_ms.load() < kResultGraceMs;
}
}  // namespace voice

extern "C" bool lifeline_voice_busy() { return voice::busy(); }

// Emulation thread, while a slot is saved: the active context, stored next to the state ("" if unknown).
extern "C" const char *lifeline_voice_context() {
    using namespace voice;
    return g_registered && g.context.size() > 4 && g.context != "?" ? g.context.c_str() : "";
}

// Emulation thread, right after a slot was loaded: the game's memory is from the state, our side is not.
// Drop the capture and pending context, restore the saved context's vocabulary, and if the state was taken
// mid-listen put the game's recognizer (kState, 0x2DBE38) back to idle so the next push-to-talk starts fresh.
extern "C" void lifeline_voice_after_load(const char *context) {
    using namespace voice;
    if (!g_registered) return;
    load_once();
    if (g_listening) { g.rec->stop(); Recognition drop; while (g.rec->poll(drop)) {} }
    g_listening = g_identifying = false;
    g_result_ms = 0;
    g.pend_ctx = g.pend_wrd = 0;
    g.vgp.reset(); g.vgp_base = 0;
    g.vocab_from.clear();
    g.context = context && *context ? context : "?";
    if (g.context != "?") vocab_for_context();
    const std::uint32_t st = ps2::ld32(kState);
    if (st == 1) write_no_result();   // listening -> idle (2), no words
    std::fprintf(stderr, "[voice] f%llu state loaded: context %s, recognizer %s\n", (unsigned long long)now(), g.context.c_str(),
                 st == 1 ? "was listening, reset to idle" : "idle");
}
