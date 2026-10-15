// Writes a recognition result into the game's speech recognizer's globals the same way its own result handler does.
#pragma once
#include <cstdint>
#include <string>
#include <vector>
namespace voice {
// words: phrase strings (at most 10 kept, each < 64 bytes). confidence: 0..9999.
// result_id: the id the game's GetResultId() returns when accepted (-1 forced if below threshold).
void write_result(const std::vector<std::string> &words, std::uint16_t confidence, std::int32_t result_id);
void write_no_result();
}
