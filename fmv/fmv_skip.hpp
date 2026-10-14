// FMV skip (Lifeline Recomp, PS2_FMV_SKIP=1). Ends a movie on a fresh Start press, the same way the movie ends by
// itself: the game's movie player's per-frame update (0x1E7F08, a0 = player) is a state machine at player+0; state 5 is "playing"
// (with player+0x538 == 1, the stream is open), and when the decoder reports the end it moves to 6, which stops
// the sound, closes the stream and goes 7 -> 8 -> 9 (closed). We set 5 -> 6 early (same as
// the game's movie player's own abort routine at 0x1E85D0). Only this movie player is touched: spoken prompts and dialog use the
// voice engine and should not go through it (checked on the intro movie only; the other full-screen
// movies have not been checked).
#pragma once
#include <cstdint>

namespace fmv {
constexpr std::uint32_t kPlayerUpdate = 0x1E7F08;
// Two kinds of caller run the update every frame:
//  - the single full-screen movie object (script cmds around 0x124390-0x124860; per-frame 0x1244C8 calls the update
//    for the player at object+0x10 and returns to 0x1244E8; its stop command 0x124470 is the abort routine caller
//    returning to 0x12449C);
//  - a 16-slot player array at object+0x680 (per-frame 0x124868 returns to 0x12489C; open 0x124A70, stop/reset
//    0x1248C8 / 0x124B90 are the abort routine callers returning to 0x1249D4, 0x124C0C, 0x124C60). These are
//    movies drawn into the scene (monitors, in-world screens), where play continues around them.
// Only the full-screen movie is skippable.
constexpr std::uint32_t kFullscreenReturn = 0x1244E8, kSlotArrayReturn = 0x12489C;
inline bool skippable_caller(std::uint32_t ra) { return ra == kFullscreenReturn; }
constexpr std::uint32_t kStateOff = 0x0, kOpenOff = 0x538, kNameOff = 0x53C;
constexpr std::uint32_t kPlaying = 5, kEnding = 6;
constexpr std::uint64_t kFrameGap = 10;   // frames_run() jumping more than this (or back) = state load
constexpr std::uint16_t kStart = 1u << 3, kCircle = 1u << 13, kCross = 1u << 14;
constexpr std::uint16_t kSkipButtons = kStart;   // Start only; Cross is the confirm button, circle is push-to-talk

// One per player. Buttons already down when the movie started (or when a state was loaded mid-movie) don't count:
// it takes a new Start press during playback. A skip is refused while the voice recognizer is busy.
class SkipLogic {
public:
    enum class Why { None, Voice };
    // Called each update. Returns true when this playing movie should end now; why = reason for a refusal.
    bool update(std::uint32_t state, std::uint32_t open, std::uint16_t buttons, bool voice_busy, Why &why) {
        why = Why::None;
        const bool playing = state == kPlaying && open == 1;
        const std::uint16_t prev = prev_;
        prev_ = buttons;
        if (!playing) { armed_ = false; return false; }
        if (!armed_) { armed_ = true; return false; }
        if (!(buttons & ~prev & kSkipButtons)) return false;
        if (voice_busy) { why = Why::Voice; return false; }   // same rule as the save-slot / fast-forward hotkeys
        if (buttons & kCircle) return false;
        return true;
    }
    // After a state load (or any external reset of the player): drop the latch so a held Start does not skip.
    void clear() { armed_ = false; prev_ = 0; }
private:
    std::uint16_t prev_ = 0;
    bool armed_ = false;
};
}
