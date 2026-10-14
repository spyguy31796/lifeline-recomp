// Lifeline Recomp: save-state slots on hotkeys (SDL- and runtime-free so it can be unit-tested).
// Enabled by PS2_SAVE_SLOTS=1 (launcher QoL item 4). hk_save / hk_load act on the current slot, hk_slot picks the
// next one (1..kSlotCount). States go to PS2_SAVE_DIR (run.sh: saves/ next to it) as slotN.state, the voice
// context as slotN.voice. The runner does the actual save/load at the next frame boundary (patch 0007).
#pragma once
#include <string>

namespace lifeline_input {

constexpr int kSlotCount = 4;

enum class SlotAction { None, Save, Load, NextSlot, Blocked };

struct SlotDecision {
    SlotAction action = SlotAction::None;
    int slot = 1;               // slot the action is about (1-based)
    const char *why = "";       // Blocked: reason, for the log
};

class SaveSlots {
public:
    explicit SaveSlots(std::string dir) : dir_(std::move(dir)) {}
    // fired: 1 << kHk* bits from HotkeyState::update. talk_held: the PS2 Circle (push-to-talk) button is down.
    // voice_busy: listening / a result the game may not have read yet. in_flight: an earlier save/load is pending.
    SlotDecision on_hotkeys(unsigned fired, bool talk_held, bool voice_busy, bool in_flight);
    int slot() const { return slot_; }
    std::string state_path(int slot) const;   // <dir>/slotN.state
    std::string voice_path(int slot) const;   // <dir>/slotN.voice
    std::string backup_path() const;          // <dir>/before-load.state: what was running before the last load
    const std::string &dir() const { return dir_; }

private:
    std::string dir_;
    int slot_ = 1;
};

// Outcome of a queued save/load as the runner reports it (mirrors ps2::StateResult, patch 0007).
enum class SlotResult { Ok, Failed, Vetoed };
// What to do after a load: a veto (voice busy at the frame-boundary re-check, or the before-load backup could not
// be kept) touched nothing, so it neither restores the backup nor resets voice; only an attempted load does.
struct LoadFollowUp {
    bool restore_backup = false;   // the load was attempted and failed: go back to before-load.state
    bool reset_voice = false;      // call lifeline_voice_after_load
    bool voice_from_slot = false;  // with slotN.voice's context (Ok) or an empty one (Failed)
};
LoadFollowUp after_load(SlotResult r);

bool save_slots_enabled(const char *env);    // PS2_SAVE_SLOTS: "1" = on
std::string save_dir(const char *env);       // PS2_SAVE_DIR, default "saves"

}  // namespace lifeline_input
