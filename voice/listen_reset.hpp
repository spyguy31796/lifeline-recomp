// After a slot load taken mid-listen, the game's voice object's own listening flag (this+0x10) must go back to
// idle at its next Execute call. Runtime-free so it can be unit-tested (voice/tests/test_listen_reset.cpp).
#pragma once
#include <cstdint>

namespace voice {

class ListenReset {
public:
    static constexpr std::uint64_t kMaxFrames = 5;   // Execute runs every frame; if it doesn't run this soon, give up
    // A load finished at `frame`; recognizer_was_listening: kState was 1 (mid-listen) in the loaded state.
    // Any load replaces an earlier pending reset.
    void on_load(std::uint64_t frame, bool recognizer_was_listening) { armed_ = recognizer_was_listening; at_ = frame; }
    void on_command() { armed_ = false; }            // cmd 1 / cmd 2: the game has moved on
    // Execute at `frame`: true = clear this+0x10 now. Disarms in every case; never clears while our side listens.
    bool on_execute(std::uint64_t frame, bool we_are_listening) {
        if (!armed_) return false;
        armed_ = false;
        return frame - at_ <= kMaxFrames && !we_are_listening;
    }
    bool armed() const { return armed_; }

private:
    bool armed_ = false;
    std::uint64_t at_ = 0;
};

}  // namespace voice
