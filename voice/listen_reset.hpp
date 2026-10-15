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
    void on_load(std::uint64_t frame, bool recognizer_was_listening) { armed_ = recognizer_was_listening; at_ = frame; resync_ = false; }
    void on_command() { armed_ = false; }            // cmd 1 / cmd 2: the game has moved on
    // Execute at `frame`: true = clear this+0x10 now. Disarms in every case; never clears while our side listens.
    bool on_execute(std::uint64_t frame, bool we_are_listening) {
        if (!armed_) return false;
        armed_ = false;
        return frame - at_ <= kMaxFrames && !we_are_listening;
    }
    bool armed() const { return armed_; }
    // The game's held-button mask restored from the state can still say Circle is down (it was held at save time),
    // and it keeps saying so for a few frames until fresh pad data reaches the game. Execute starts a listen whenever
    // its flag is idle and that bit is set, so from the reset frame on the bit is held to the real pad until the
    // game's own mask goes up by itself or Circle is really pressed: a listen starts only on a real press.
    void start_resync() { resync_ = true; noted_ = false; }   // each resync logs its first hold again
    // True once per resync: the first frame the restored bit is held up (for a single log line).
    bool note_hold_once() { if (noted_) return false; noted_ = true; return true; }
    // The pad record pointer read from game memory: write through it only if the held mask word lies inside
    // PS2 main RAM (32 MB, uncached mirrors stripped) and is word-aligned. Rejects 0 and garbage pointers.
    static constexpr std::uint32_t kMainRamSize = 0x02000000;
    static bool pad_word_ok(std::uint32_t pad, std::uint32_t off) {
        if (pad == 0) return false;
        const std::uint64_t a = std::uint64_t(pad & 0x0FFFFFFFu) + off;
        return (a & 3) == 0 && a + 4 <= kMainRamSize;
    }
    // Execute: the game's mask now; returns the mask the game should see this frame.
    std::uint32_t resync_held(std::uint32_t mask, std::uint32_t circle_bit, bool physically_held) {
        if (!resync_) return mask;
        if (physically_held || !(mask & circle_bit)) { resync_ = false; return mask; }   // real press, or caught up
        return mask & ~circle_bit;
    }
    bool resyncing() const { return resync_; }
    void cancel_resync() { resync_ = false; }

private:
    bool armed_ = false;
    bool resync_ = false;
    bool noted_ = false;
    std::uint64_t at_ = 0;
};

}  // namespace voice
