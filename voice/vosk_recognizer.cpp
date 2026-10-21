// Vosk (Apache-2.0) backend. libvosk is loaded at run time so the build has no hard dependency.
// Environment: PS2_VOICE_VOSK_LIB (default libvosk.so; libvosk.dll on Windows), PS2_VOICE_VOSK_MODEL (model directory, required).
#include "audio_source.hpp"
#include "recognizer.hpp"
#include "speech_forms.hpp"
#include "slot_match.hpp"
#include "env_path.hpp"
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <optional>
#include <sstream>
namespace voice {
namespace {
struct Api {
    void *h = nullptr;
    void *(*model_new)(const char *);
    void *(*rec_new_grm)(void *, float, const char *);
    void (*rec_set_words)(void *, int);
    int (*accept_s)(void *, const short *, int);
    const char *(*final_result)(void *);
    void (*rec_free)(void *);
    void (*set_log_level)(int);
    bool load(const char *lib) {
#ifdef _WIN32
        h = win_load(lib);
        if (!h) return false;
        auto sym = [&](const char *n) {
            void *p = reinterpret_cast<void *>(GetProcAddress(static_cast<HMODULE>(h), n));
            if (!p) std::fprintf(stderr, "[voice] vosk: %s: missing %s\n", lib, n);
            return p;
        };
#else
        h = dlopen(lib, RTLD_NOW);
        if (!h) { std::fprintf(stderr, "[voice] vosk: %s\n", dlerror()); return false; }
        auto sym = [&](const char *n) { void *p = dlsym(h, n); if (!p) std::fprintf(stderr, "[voice] vosk: missing %s\n", n); return p; };
#endif
        model_new = (decltype(model_new))sym("vosk_model_new");
        rec_new_grm = (decltype(rec_new_grm))sym("vosk_recognizer_new_grm");
        rec_set_words = (decltype(rec_set_words))sym("vosk_recognizer_set_words");
        accept_s = (decltype(accept_s))sym("vosk_recognizer_accept_waveform_s");
        final_result = (decltype(final_result))sym("vosk_recognizer_final_result");
        rec_free = (decltype(rec_free))sym("vosk_recognizer_free");
        set_log_level = (decltype(set_log_level))sym("vosk_set_log_level");
        if (model_new && rec_new_grm && rec_set_words && accept_s && final_result && rec_free && set_log_level) return true;
        // A library without the full API is not used: unload it instead of leaking the handle.
#ifdef _WIN32
        FreeLibrary(static_cast<HMODULE>(h));
#else
        dlclose(h);
#endif
        h = nullptr;
        return false;
    }
#ifdef _WIN32
    // System message for a Win32 error code, without the trailing CR/LF.
    static std::string win_error_text(DWORD e) {
        char *buf = nullptr;
        const DWORD n = FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                                       nullptr, e, 0, reinterpret_cast<char *>(&buf), 0, nullptr);
        std::string s = n && buf ? std::string(buf, n) : std::string("(no system message)");
        if (buf) LocalFree(buf);
        while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' ')) s.pop_back();
        return s;
    }
    static std::wstring widen(const char *s) {
        const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, nullptr, 0);
        if (n <= 0) return {};
        std::wstring w(static_cast<std::size_t>(n), L'\0');
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w.data(), n);
        w.resize(static_cast<std::size_t>(n - 1));
        return w;
    }
    // A path with a folder in it is made absolute and loaded with LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, so the
    // MinGW runtime DLLs shipped next to libvosk.dll (libgcc_s_seh-1, libstdc++-6, libwinpthread-1) are found
    // there first; that flag needs a fully qualified path. A bare file name keeps the normal LoadLibrary search
    // (exe folder, system folders, PATH).
    static void *win_load(const char *lib) {
        const std::wstring w = widen(lib);
        if (w.empty()) {
            std::fprintf(stderr, "[voice] vosk: %s: LoadLibrary failed, path is not valid UTF-8\n", lib);
            return nullptr;
        }
        HMODULE m = nullptr;
        if (w.find_first_of(L"\\/:") == std::wstring::npos) {
            m = LoadLibraryW(w.c_str());
        } else {
            const DWORD n = GetFullPathNameW(w.c_str(), 0, nullptr, nullptr);
            std::wstring full(n ? n : 1, L'\0');
            const DWORD got = n ? GetFullPathNameW(w.c_str(), n, full.data(), nullptr) : 0;
            if (got == 0 || got >= n) {
                const DWORD e = GetLastError();
                std::fprintf(stderr, "[voice] vosk: %s: LoadLibrary failed, error %lu %s (GetFullPathName)\n", lib,
                             static_cast<unsigned long>(e), win_error_text(e).c_str());
                return nullptr;
            }
            full.resize(got);
            m = LoadLibraryExW(full.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        }
        if (!m) {
            const DWORD e = GetLastError();
            std::fprintf(stderr, "[voice] vosk: %s: LoadLibrary failed, error %lu %s\n", lib, static_cast<unsigned long>(e),
                         win_error_text(e).c_str());
        }
        return m;
    }
#endif
};
std::string json_str(const std::string &j, const std::string &key) {
    const auto k = j.find("\"" + key + "\""); if (k == std::string::npos) return {};
    const auto a = j.find('"', j.find(':', k) + 1); const auto b = j.find('"', a + 1);
    return a == std::string::npos || b == std::string::npos ? std::string() : j.substr(a + 1, b - a - 1);
}
std::vector<double> json_nums(const std::string &j, const std::string &key) {
    std::vector<double> v;
    for (auto k = j.find("\"" + key + "\""); k != std::string::npos; k = j.find("\"" + key + "\"", k + 1))
        v.push_back(std::atof(j.c_str() + j.find(':', k) + 1));
    return v;
}
class VoskRecognizer final : public Recognizer {
public:
    VoskRecognizer(Api api, void *model, std::unique_ptr<AudioSource> src) : api_(api), model_(model), src_(std::move(src)) {}
    void set_vocabulary(const std::vector<std::string> &phrases, const std::vector<int> &classes) override {
        map_.clear(); fold_.clear();
        std::string g = "[";
        std::size_t n = 0;
        // Pass 0 registers every phrase's primary form, pass 1 the homophone variants, so a variant of one
        // phrase never shadows another phrase's own spelling (e.g. "two" vs a separate "too" entry).
        for (int pass = 0; pass < 2; ++pass)
            for (const auto &p : phrases) {
                const auto forms = spoken_forms(p);  // empty for dummy / non-ASCII system tokens
                for (std::size_t i = pass ? 1 : 0; i < (pass ? forms.size() : std::min<std::size_t>(1, forms.size())); ++i) {
                    if (map_.emplace(forms[i], p).second) { g += "\"" + forms[i] + "\","; n += !pass; }
                    fold_.emplace(homophone_key(forms[i]), p);  // first VGP spelling wins
                }
            }
        // Generic filler and verb-synonym words, so natural sentences decode word for word.
        slot_.build(phrases, classes);
        std::size_t extra = 0;
        for (const auto &w : slot_.grammar_words()) if (!map_.count(w)) { g += "\"" + w + "\","; ++extra; }
        g += "\"[unk]\"]";
        grammar_ = g;
        if (rec_) { api_.rec_free(rec_); rec_ = nullptr; }
        std::fprintf(stderr, "[voice] vosk grammar: %zu phrases, %zu spoken forms, %zu filler/synonym words (+[unk])\n", n, map_.size(), extra);
    }
    void start() override { if (src_) src_->start(); }
    void stop() override {
        if (!src_) return;
        const auto pcm = src_->stop();
        if (pcm.empty()) return;
        if (!rec_) {
            if (grammar_.empty()) { std::fprintf(stderr, "[voice] vosk: no vocabulary yet\n"); return; }
            rec_ = api_.rec_new_grm(model_, 16000.f, grammar_.c_str());
            api_.rec_set_words(rec_, 1);
        }
        const auto t0 = std::chrono::steady_clock::now();
        for (std::size_t o = 0; o < pcm.size(); o += 4000) api_.accept_s(rec_, pcm.data() + o, int(std::min<std::size_t>(4000, pcm.size() - o)));
        const std::string j = api_.final_result(rec_);  // also resets the recognizer for the next utterance
        Recognition r;
        r.latency_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        r.raw = json_str(j, "text");
        const auto confs = json_nums(j, "conf");
        double c = 0; for (double x : confs) c += x; c = confs.empty() ? 0 : c / confs.size();
        r.confidence = static_cast<std::uint16_t>(c * 10000 + 0.5);
        r.words = segment(r.raw);
        r.how = r.words.empty() ? "" : "exact";
        // Natural sentence: tolerant slot match, only for confidently decoded speech.
        if (r.words.empty() && !r.raw.empty()) {
            if (r.confidence >= kFuzzyMinConf) r.words = slot_.match(r.raw, &r.how);
            else r.how = "low confidence";
        }
        r.audio_ms = pcm.size() / 16.0;
        r.clip = src_->last_clip();
        pending_ = r;
    }
    bool poll(Recognition &out) override {
        if (!pending_) return false;
        out = *pending_; pending_.reset(); return true;
    }
    // A Vosk grammar accepts any sequence of its phrases, and slot contexts rely on that: a command is
    // a verb phrase followed by an object phrase, each its own VGP entry (VoCon returned one word string
    // per entry, and the game's matcher combines their class slots). Split the decoded text into the
    // fewest VGP phrases (exact spoken form first, then homophone-folded); any unmatched span rejects.
    std::vector<std::string> segment(const std::string &raw) const {
        std::vector<std::string> t;
        { std::istringstream in(raw); for (std::string w; in >> w;) t.push_back(w); }
        const std::size_t n = t.size();
        if (!n) return {};
        constexpr int kInf = 1 << 20;
        std::vector<int> best(n + 1, kInf), cost(n + 1, kInf);
        std::vector<std::size_t> from(n + 1, 0);
        std::vector<std::string> pick(n + 1);
        best[0] = 0; cost[0] = 0;
        for (std::size_t i = 0; i < n; ++i) {
            if (best[i] == kInf) continue;
            std::string key;
            for (std::size_t j = i; j < n && j < i + 12; ++j) {
                key += (j > i ? " " : "") + t[j];
                const std::string *hit = nullptr; int c = 0;
                if (auto it = map_.find(key); it != map_.end()) hit = &it->second;
                else if (auto f = fold_.find(homophone_key(key)); f != fold_.end()) { hit = &f->second; c = 1; }
                if (!hit) continue;
                if (best[i] + 1 < best[j + 1] || (best[i] + 1 == best[j + 1] && cost[i] + c < cost[j + 1])) {
                    best[j + 1] = best[i] + 1; cost[j + 1] = cost[i] + c; from[j + 1] = i; pick[j + 1] = *hit;
                }
            }
        }
        if (best[n] == kInf || best[n] > 10) return {};
        std::vector<std::string> out;
        for (std::size_t k = n; k > 0; k = from[k]) out.push_back(pick[k]);
        return {out.rbegin(), out.rend()};
    }
    const AudioSource *source() const { return src_.get(); }
private:
    Api api_; void *model_; void *rec_ = nullptr;
    std::unique_ptr<AudioSource> src_;
    static constexpr std::uint16_t kFuzzyMinConf = 6000;  // mean Vosk word confidence x 10000
    SlotMatcher slot_;
    std::map<std::string, std::string> map_;   // spoken form -> exact VGP phrase
    std::map<std::string, std::string> fold_;  // homophone_key(spoken form) -> exact VGP phrase
    std::string grammar_;
    std::optional<Recognition> pending_;
};
}
std::unique_ptr<Recognizer> make_vosk_recognizer() {
    const auto model_env = env_utf8("PS2_VOICE_VOSK_MODEL");  // UTF-8 (wide environment on Windows)
    if (!model_env) return nullptr;
    const char *model_dir = model_env->c_str();
    const auto lib_env = env_utf8("PS2_VOICE_VOSK_LIB");
    const char *lib = lib_env ? lib_env->c_str() : nullptr;
    Api api;
#ifdef _WIN32
    constexpr const char *kDefaultLib = "libvosk.dll";
#else
    constexpr const char *kDefaultLib = "libvosk.so";
#endif
    if (!api.load(lib ? lib : kDefaultLib)) return nullptr;
    api.set_log_level(-1);
    // vosk_model_new takes a narrow path; on Windows that is the ANSI code page (or the 8.3 short name).
    bool lossy = false;
    const std::string model_arg = narrow_api_path(*model_env, &lossy);
    if (lossy) std::fprintf(stderr, "[voice] vosk: model path %s has characters outside the ANSI code page and no short name; it may not load\n", model_dir);
    void *model = api.model_new(model_arg.c_str());
    if (!model) { std::fprintf(stderr, "[voice] vosk: cannot load model %s\n", model_dir); return nullptr; }
    load_aliases();
    auto src = make_audio_source_from_env();
    std::fprintf(stderr, "[voice] vosk backend: model %s, audio source %s\n", model_dir, src ? src->name() : "none");
    return std::make_unique<VoskRecognizer>(api, model, std::move(src));
}
}
