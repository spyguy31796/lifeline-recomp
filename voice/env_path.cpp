#include "env_path.hpp"
#include <cstdlib>
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <wchar.h>
#endif
namespace voice {
#ifdef _WIN32
namespace {
std::wstring widen(const std::string &s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), int(s.size()), nullptr, 0);
    if (n <= 0) return {};
    std::wstring w(static_cast<std::size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), int(s.size()), w.data(), n);
    return w;
}
std::string narrow(const std::wstring &w, UINT cp, bool *lossy) {
    if (lossy) *lossy = false;
    if (w.empty()) return {};
    BOOL used = FALSE;
    // WC_NO_BEST_FIT_CHARS and lpUsedDefaultChar are not allowed with CP_UTF8.
    const bool acp = cp != CP_UTF8;
    const int n = WideCharToMultiByte(cp, acp ? WC_NO_BEST_FIT_CHARS : 0, w.data(), int(w.size()), nullptr, 0, nullptr, acp ? &used : nullptr);
    if (n <= 0) { if (lossy) *lossy = true; return {}; }
    std::string s(static_cast<std::size_t>(n), '\0');
    WideCharToMultiByte(cp, acp ? WC_NO_BEST_FIT_CHARS : 0, w.data(), int(w.size()), s.data(), n, nullptr, acp ? &used : nullptr);
    if (lossy) *lossy = used != FALSE;
    return s;
}
}
std::optional<std::string> env_utf8(const char *name) {
    const std::wstring wn = widen(name);
    const wchar_t *v = _wgetenv(wn.c_str());
    if (!v) return std::nullopt;
    return narrow(v, CP_UTF8, nullptr);
}
std::filesystem::path u8_path(const std::string &utf8) { return std::filesystem::path(widen(utf8)); }
std::string path_utf8(const std::filesystem::path &p) { return narrow(p.native(), CP_UTF8, nullptr); }
std::FILE *fopen_utf8(const std::string &utf8, const char *mode) {
    return _wfopen(widen(utf8).c_str(), widen(mode).c_str());
}
std::string narrow_api_path(const std::string &utf8, bool *lossy) {
    const std::wstring w = widen(utf8);
    bool bad = false;
    std::string a = narrow(w, CP_ACP, &bad);
    if (!bad && !a.empty()) { if (lossy) *lossy = false; return a; }
    const DWORD n = GetShortPathNameW(w.c_str(), nullptr, 0);
    if (n) {
        std::wstring s(n, L'\0');
        const DWORD got = GetShortPathNameW(w.c_str(), s.data(), n);
        if (got && got < n) {
            s.resize(got);
            a = narrow(s, CP_ACP, &bad);
            if (!bad && !a.empty()) { if (lossy) *lossy = false; return a; }
        }
    }
    if (lossy) *lossy = true;
    return utf8;
}
#else
std::optional<std::string> env_utf8(const char *name) {
    const char *v = std::getenv(name);
    if (!v) return std::nullopt;
    return std::string(v);
}
std::filesystem::path u8_path(const std::string &utf8) { return std::filesystem::path(utf8); }
std::string path_utf8(const std::filesystem::path &p) { return p.string(); }
std::FILE *fopen_utf8(const std::string &utf8, const char *mode) { return std::fopen(utf8.c_str(), mode); }
std::string narrow_api_path(const std::string &utf8, bool *lossy) { if (lossy) *lossy = false; return utf8; }
#endif
}
