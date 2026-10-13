#include "result_writer.hpp"
#include "lifeline_addrs.hpp"
#include "ps2/memory.hpp"
namespace voice {
using namespace addr;
static void clear_words() {
    for (std::uint32_t i = 0; i < 0x400; i += 4) ps2::st32(kWordBuf + i, 0);
    for (int i = 0; i < kMaxWords; ++i) ps2::st32(kWordPtrs + 4u * i, 0);
}
void write_no_result() {
    clear_words();
    ps2::st32(kState, 2); ps2::st32(kConfidence, 0); ps2::st32(kResultId, 0xFFFFFFFFu); ps2::st32(kWordCount, 0);
}
void write_result(const std::vector<std::string> &words, std::uint16_t confidence, std::int32_t result_id) {
    clear_words();
    int n = 0;
    for (const auto &w : words) {
        if (n == kMaxWords || w.empty()) continue;
        const std::uint32_t dst = kWordBuf + static_cast<std::uint32_t>(n) * kWordLen;
        const std::size_t len = w.size() < kWordLen - 1 ? w.size() : kWordLen - 1;
        for (std::size_t i = 0; i < len; ++i) ps2::st8(dst + i, static_cast<std::uint8_t>(w[i]));
        ps2::st8(dst + len, 0);
        ps2::st32(kWordPtrs + 4u * n, dst);
        ++n;
    }
    ps2::st32(kWordCount, static_cast<std::uint32_t>(n));
    ps2::st32(kConfidence, confidence);
    const std::int32_t threshold = static_cast<std::int32_t>(ps2::ld32(kThreshold));
    ps2::st32(kResultId, static_cast<std::uint32_t>(confidence < threshold ? -1 : result_id));
    ps2::st32(kState, 3);
}
}
