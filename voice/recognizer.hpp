// Interface for the native speech recognizer backends (null, Vosk).
#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
namespace voice {
struct Recognition {
    std::vector<std::string> words;   // matched VGP phrase(s), exactly as spelled in the table
    std::uint16_t confidence = 0;     // 0..10000
    std::string raw;                  // backend's raw text
    double latency_ms = 0;            // end of audio -> final result
    double audio_ms = 0;              // length of the utterance
    std::string clip;                 // file source: clip that was played
    std::string how;                  // "exact", "fuzzy" or the reject reason
};
class Recognizer {
public:
    virtual ~Recognizer() = default;
    // Restrict recognition to these phrases (the active context's VGP phrases).
    // `classes` (optional, parallel to phrases) are the VGP class slots, used by the tolerant matcher.
    virtual void set_vocabulary(const std::vector<std::string> &phrases, const std::vector<int> &classes = {}) = 0;
    virtual void start() = 0;  // push-to-talk pressed: begin capturing audio
    virtual void stop() = 0;   // released: finish decoding (synchronous)
    // Non-blocking: returns true and fills `out` when a final result is ready. A result with
    // empty `words` is a rejection (off-grammar / silence) and is still reported once.
    virtual bool poll(Recognition &out) = 0;
};
std::unique_ptr<Recognizer> make_null_recognizer();
// Vosk backend (libvosk loaded with dlopen). Returns nullptr if the library or model is unavailable.
std::unique_ptr<Recognizer> make_vosk_recognizer();
}
