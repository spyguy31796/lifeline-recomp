// Lifeline Recomp: PS2_INPUT_MAP parser (SDL-free so it can be unit-tested).
#include "input_map.hpp"
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <climits>
#include <cstdlib>

namespace lifeline_input {
namespace {
// SDL_GameControllerButton / Axis values (stable SDL2 ABI).
const char *kButtons[] = {"a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick",
                          "leftshoulder", "rightshoulder", "dpup", "dpdown", "dpleft", "dpright",
                          "misc1", "paddle1", "paddle2", "paddle3", "paddle4", "touchpad"};
const char *kAxes[] = {"leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger"};
const char *kTargets[] = {"select", "l3", "r3", "start", "up", "right", "down", "left",
                          "l2", "r2", "l1", "r1", "triangle", "circle", "cross", "square",
                          "lx", "ly", "rx", "ry"};

std::string trim(std::string s) {
    auto ws = [](unsigned char c) { return std::isspace(c); };
    while (!s.empty() && ws(s.back())) s.pop_back();
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), [&](unsigned char c) { return !ws(c); }));
    return s;
}
std::string lower(std::string s) { for (auto &c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c))); return s; }
// Non-negative decimal index 0..kMaxIndex, whole string, via strtol with range checks.
constexpr long kMaxIndex = 255;
bool parse_int(const std::string &s, int &v) {
    if (s.empty() || !std::isdigit(static_cast<unsigned char>(s[0]))) return false;   // no sign, no spaces
    errno = 0;
    char *end = nullptr;
    const long n = std::strtol(s.c_str(), &end, 10);
    if (errno == ERANGE || end != s.c_str() + s.size() || n < 0 || n > kMaxIndex) return false;
    v = static_cast<int>(n);
    return true;
}
template <std::size_t N> int find(const char *(&t)[N], const std::string &n) {
    for (std::size_t i = 0; i < N; ++i) if (n == t[i]) return static_cast<int>(i);
    return -1;
}
}  // namespace

bool target_from_name(const std::string &n, int &out) { out = find(kTargets, lower(trim(n))); return out >= 0; }

bool parse_source(const std::string &raw, Source &o, std::string &err) {
    std::string s = trim(raw);
    o = Source{};
    if (s.rfind("key:", 0) == 0) {           // keep case: SDL scancode names are case-insensitive anyway
        o.kind = Kind::Key; o.key = trim(s.substr(4));
        if (o.key.empty()) { err = "empty key name"; return false; }
        return true;
    }
    s = lower(s);
    if (!s.empty() && s.back() == '~') { o.invert = true; s.pop_back(); }
    if (s.rfind("joy:", 0) == 0) {
        std::string r = s.substr(4);
        if (r.size() > 1 && r[0] == 'b') { o.kind = Kind::JoyButton; if (parse_int(r.substr(1), o.index)) return true; }
        else if (r.size() > 1 && r[0] == 'a') {
            o.kind = Kind::JoyAxis;
            if (r.back() == '+' || r.back() == '-') { o.sign = r.back() == '+' ? 1 : -1; r.pop_back(); }
            if (parse_int(r.substr(1), o.index)) return true;
        } else if (r.size() > 1 && r[0] == 'h') {
            const auto dot = r.find('.');
            o.kind = Kind::JoyHat;
            const std::string dir = dot == std::string::npos ? "" : r.substr(dot + 1);
            o.hat_mask = dir == "up" ? 1 : dir == "right" ? 2 : dir == "down" ? 4 : dir == "left" ? 8 : 0;
            if (o.hat_mask && parse_int(r.substr(1, dot - 1), o.index)) return true;
        }
        err = "bad joystick source '" + raw + "'"; return false;
    }
    if (!s.empty() && (s[0] == '+' || s[0] == '-')) { o.sign = s[0] == '+' ? 1 : -1; s.erase(0, 1); }
    if (int a = find(kAxes, s); a >= 0) { o.kind = Kind::Axis; o.index = a; return true; }
    if (int b = find(kButtons, s); b >= 0 && o.sign == 0 && !o.invert) { o.kind = Kind::Button; o.index = b; return true; }
    err = "unknown source '" + raw + "'"; return false;
}

int invert_axis(int v) { return v <= -32767 ? 32767 : v == 0 ? 0 : -v; }   // 0 stays 0, so rest stays 0x80

std::uint8_t axis_to_u8(int v, bool invert) {
    if (invert) v = invert_axis(v);
    return static_cast<std::uint8_t>(std::clamp((v + 32768) >> 8, 0, 255));
}

Map default_map() {   // identical to the runner's built-in pad table
    Map m;
    auto set = [&](int t, const char *s) { Source x; std::string e; parse_source(s, x, e); m.src[t].push_back(x); m.bound[t] = true; };
    set(kCross, "a"); set(kCircle, "b"); set(kSquare, "x"); set(kTriangle, "y");
    set(kL1, "leftshoulder"); set(kR1, "rightshoulder"); set(kL2, "lefttrigger"); set(kR2, "righttrigger");
    set(kL3, "leftstick"); set(kR3, "rightstick"); set(kSelect, "back"); set(kStart, "start");
    set(kUp, "dpup"); set(kDown, "dpdown"); set(kLeft, "dpleft"); set(kRight, "dpright");
    set(kLX, "leftx"); set(kLY, "lefty"); set(kRX, "rightx"); set(kRY, "righty");
    return m;
}

bool parse_map(const std::string &spec, Map &out, std::string &err) {
    out = default_map();
    bool ok = true;
    std::size_t p = 0;
    while (p <= spec.size()) {
        std::size_t q = spec.find(';', p); if (q == std::string::npos) q = spec.size();
        const std::string ent = trim(spec.substr(p, q - p)); p = q + 1;
        if (ent.empty()) continue;
        const auto eq = ent.find('=');
        int t;
        if (eq == std::string::npos || !target_from_name(ent.substr(0, eq), t)) { err += "bad entry '" + ent + "'; "; ok = false; continue; }
        std::vector<Source> v; bool good = true;
        std::string rhs = lower(trim(ent.substr(eq + 1)));
        if (rhs != "none" && !rhs.empty()) {
            std::size_t a = 0; const std::string r = trim(ent.substr(eq + 1));
            while (a <= r.size()) {
                std::size_t b = r.find(',', a); if (b == std::string::npos) b = r.size();
                Source s; std::string e;
                if (parse_source(r.substr(a, b - a), s, e)) {
                    const bool analog = t >= kLX;
                    const bool axis = s.kind == Kind::Axis || s.kind == Kind::JoyAxis;
                    if (analog && (!axis || s.sign)) { e = "stick target needs a whole axis, got '" + r.substr(a, b - a) + "'"; good = false; err += e + "; "; }
                    else v.push_back(s);
                } else { good = false; err += e + "; "; }
                a = b + 1;
            }
        }
        if (!good) ok = false;
        if (good || !v.empty()) { out.src[t] = v; out.bound[t] = true; }
    }
    out.active = true;
    return ok;
}

}  // namespace lifeline_input
