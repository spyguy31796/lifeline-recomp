// Addresses in Lifeline (SLUS_208.48) used by the voice replacement. See VOICE-MAP.md.
#pragma once
#include <cstdint>
namespace voice::addr {
constexpr std::uint32_t kInitEngine   = 0x1C7950;
constexpr std::uint32_t kClose        = 0x1C7C50;
constexpr std::uint32_t kPostMessage  = 0x1C8D60;
constexpr std::uint32_t kGetStatus    = 0x1C84E0;
constexpr std::uint32_t kMatcher      = 0x1AD8B0;
constexpr std::uint32_t kState        = 0x2DBE38; // 1 listening, 2 idle, 3 result
constexpr std::uint32_t kThreshold    = 0x2DBE4C;
constexpr std::uint32_t kConfidence   = 0x2DBE54;
constexpr std::uint32_t kThreadActive = 0x2DBE58;
// Game side: the game's voice object, Execute(this), polled every frame. this+0x10 is its own "listening" flag: set to 1
// right after StartListening (0x143580/0x143590), cleared after StopListening (0x143534/0x143540). With it
// set, the next Circle edge takes the stop path (cmd 2) instead of the start path (cmd 1).
constexpr std::uint32_t kVoiceObjExecute      = 0x143368;
constexpr std::uint32_t kVoiceObjListeningOff = 0x10;
constexpr std::uint32_t kWordCount    = 0x34F43C;
constexpr std::uint32_t kResultId     = 0x34F440;
constexpr std::uint32_t kWordBuf      = 0x3F6600; // 10 x 64
constexpr std::uint32_t kWordPtrs     = 0x3F6AA0; // char*[10]
constexpr int kMaxWords = 10, kWordLen = 64;
}
