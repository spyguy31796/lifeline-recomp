// Audio input for the recognizer: 16 kHz mono signed 16-bit.
#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
namespace voice {
class AudioSource {
public:
    virtual ~AudioSource() = default;
    virtual const char *name() const = 0;
    virtual void start() = 0;                       // listen window opens
    virtual std::vector<std::int16_t> stop() = 0;   // window closes: all audio captured during it
    virtual std::string last_clip() const { return {}; }
};
// PS2_VOICE_WAV_SCHEDULE=<file> ("FRAME path.wav" lines: the clip for the first listen at/after FRAME),
// else PS2_VOICE_WAV_DIR=<dir> (each listen plays the next .wav in name order),
// else SDL capture from the default microphone (when built with SDL), else nullptr.
std::unique_ptr<AudioSource> make_audio_source_from_env();
// Read a 16 kHz mono 16-bit PCM WAV. Returns empty on any other format.
std::vector<std::int16_t> read_wav16k(const std::string &path);
}
