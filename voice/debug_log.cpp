#include "debug_log.hpp"
#include "env_path.hpp"
#include <cstdio>
#include <cstdlib>
#include <mutex>
namespace voice {
bool debug_enabled() {
    static const bool on = [] { const char *d = std::getenv("PS2_VOICE_DEBUG"); return d && *d == '1'; }();
    return on;
}
void debug_log(const std::string &line) {
    if (!debug_enabled()) return;
    static std::mutex m; static std::FILE *f = nullptr;
    std::lock_guard<std::mutex> l(m);
    if (!f) { const auto p = env_utf8("PS2_VOICE_LOG"); f = fopen_utf8(p && !p->empty() ? *p : std::string("voice.log"), "a"); if (!f) return; }
    std::fprintf(f, "%s\n", line.c_str()); std::fflush(f);
}
}
