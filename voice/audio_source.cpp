#include "audio_source.hpp"
#include "env_path.hpp"
#include "ps2/system.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
// PS2_WINDOW means ps2run links SDL2 (CMake found it). The include dir differs by package: SDL2::SDL2 from
// the Windows VC package (and sdl2-config on Linux) points at the folder holding SDL.h, a bare system
// include path only has <SDL2/SDL.h>. A window build without either header is an error, not a silent
// build without the microphone.
#if defined(PS2_WINDOW)
#if __has_include(<SDL.h>)
#include <SDL.h>
#elif __has_include(<SDL2/SDL.h>)
#include <SDL2/SDL.h>
#else
#error "PS2_WINDOW is set but neither <SDL.h> nor <SDL2/SDL.h> is on the include path: the microphone source needs SDL2"
#endif
#define VOICE_HAVE_SDL 1
#endif
namespace voice {
std::vector<std::int16_t> read_wav16k(const std::string &path) {
    std::ifstream f(u8_path(path), std::ios::binary);
    std::vector<std::uint8_t> b((std::istreambuf_iterator<char>(f)), {});
    if (b.size() < 44 || std::memcmp(b.data(), "RIFF", 4) || std::memcmp(b.data() + 8, "WAVE", 4)) return {};
    auto u16 = [&](std::size_t o) { return std::uint16_t(b[o] | b[o + 1] << 8); };
    auto u32 = [&](std::size_t o) { return std::uint32_t(u16(o) | std::uint32_t(u16(o + 2)) << 16); };
    std::size_t o = 12; bool fmt_ok = false;
    while (o + 8 <= b.size()) {
        const std::uint32_t len = u32(o + 4);
        if (!std::memcmp(&b[o], "fmt ", 4)) fmt_ok = u16(o + 8) == 1 && u16(o + 10) == 1 && u32(o + 12) == 16000 && u16(o + 22) == 16;
        if (!std::memcmp(&b[o], "data", 4)) {
            if (!fmt_ok) return {};
            const std::size_t n = std::min<std::size_t>(len, b.size() - o - 8) / 2;
            std::vector<std::int16_t> s(n);
            std::memcpy(s.data(), &b[o + 8], n * 2);
            return s;
        }
        o += 8 + len + (len & 1);
    }
    return {};
}
namespace {
class WavSource final : public AudioSource {
public:
    struct Item { std::uint64_t frame; std::string path; bool used = false; };
    explicit WavSource(std::vector<Item> items) : items_(std::move(items)) {}
    const char *name() const override { return "wav"; }
    void start() override {
        cur_.clear();
        for (auto &i : items_) if (!i.used && ps2::frame_count() >= i.frame) { i.used = true; cur_ = i.path; break; }
    }
    std::vector<std::int16_t> stop() override {
        if (cur_.empty()) return {};
        auto s = read_wav16k(cur_);
        if (s.empty()) std::fprintf(stderr, "[voice] %s: not a 16 kHz mono 16-bit WAV\n", cur_.c_str());
        return s;
    }
    std::string last_clip() const override { return cur_; }
private:
    std::vector<Item> items_;
    std::string cur_;
};
#ifdef VOICE_HAVE_SDL
class SdlSource final : public AudioSource {
public:
    bool open() {
        if (!(SDL_WasInit(SDL_INIT_AUDIO) & SDL_INIT_AUDIO) && SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) {
            std::fprintf(stderr, "[voice] SDL capture: audio init failed: %s\n", SDL_GetError());
            return false;
        }
        SDL_AudioSpec want{}, have{};
        want.freq = 16000; want.format = AUDIO_S16SYS; want.channels = 1; want.samples = 512;
        want.callback = [](void *u, Uint8 *s, int n) { static_cast<SdlSource *>(u)->push(reinterpret_cast<std::int16_t *>(s), n / 2); };
        want.userdata = this;
        dev_ = SDL_OpenAudioDevice(nullptr, 1, &want, &have, 0);
        if (!dev_) { std::fprintf(stderr, "[voice] SDL capture: %s\n", SDL_GetError()); return false; }
        // nullptr opened the system default capture device; SDL >= 2.24 can report its name.
        std::string dev = "(default)";
#if SDL_VERSION_ATLEAST(2, 24, 0)
        char *def = nullptr; SDL_AudioSpec def_spec{};
        if (SDL_GetDefaultAudioInfo(&def, &def_spec, 1) == 0 && def) dev = std::string("(default) ") + def;
        SDL_free(def);
#endif
        const char *drv = SDL_GetCurrentAudioDriver();
        std::fprintf(stderr, "[voice] mic: SDL audio driver %s, capture device %s, %d Hz, format 0x%04X, %d ch, %d samples\n",
                     drv ? drv : "(none)", dev.c_str(), have.freq, static_cast<unsigned>(have.format), int(have.channels), int(have.samples));
        return true;
    }
    ~SdlSource() override { if (dev_) SDL_CloseAudioDevice(dev_); }
    const char *name() const override { return "sdl-mic"; }
    void start() override { { std::lock_guard<std::mutex> l(m_); buf_.clear(); } SDL_PauseAudioDevice(dev_, 0); }
    std::vector<std::int16_t> stop() override { SDL_PauseAudioDevice(dev_, 1); std::lock_guard<std::mutex> l(m_); return std::move(buf_); }
private:
    void push(const std::int16_t *s, int n) { std::lock_guard<std::mutex> l(m_); buf_.insert(buf_.end(), s, s + n); }
    SDL_AudioDeviceID dev_ = 0;
    std::mutex m_;
    std::vector<std::int16_t> buf_;
};
#endif
}
std::unique_ptr<AudioSource> make_audio_source_from_env() {
    std::vector<WavSource::Item> items;
    if (const auto sched = env_utf8("PS2_VOICE_WAV_SCHEDULE")) {   // schedule lines hold UTF-8 paths
        std::ifstream f(u8_path(*sched));
        for (std::string line; std::getline(f, line);) {
            if (line.empty() || line[0] == '#') continue;
            std::istringstream in(line); WavSource::Item i{}; in >> i.frame >> std::ws; std::getline(in, i.path);
            if (!i.path.empty()) items.push_back(i);
        }
        return std::make_unique<WavSource>(std::move(items));
    }
    if (const auto dir = env_utf8("PS2_VOICE_WAV_DIR")) {
        std::vector<std::string> v; std::error_code ec;
        for (const auto &e : std::filesystem::directory_iterator(u8_path(*dir), ec)) if (e.path().extension() == ".wav") v.push_back(path_utf8(e.path()));
        std::sort(v.begin(), v.end());
        for (auto &p : v) items.push_back({0, p});
        return std::make_unique<WavSource>(std::move(items));
    }
#ifdef VOICE_HAVE_SDL
    auto s = std::make_unique<SdlSource>();
    if (s->open()) return s;
    std::fprintf(stderr, "[voice] mic: cannot open the microphone, voice input is off (audio source none)\n");
#else
    std::fprintf(stderr, "[voice] mic: this ps2run was built without SDL2, voice input is off (audio source none)\n");
#endif
    return nullptr;
}
}
