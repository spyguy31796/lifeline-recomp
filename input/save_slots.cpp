// Lifeline Recomp: save-state slot decisions (see save_slots.hpp).
#include "save_slots.hpp"
#include "input_map.hpp"

namespace lifeline_input {

SlotDecision SaveSlots::on_hotkeys(unsigned fired, bool talk_held, bool voice_busy, bool in_flight) {
    SlotDecision d;
    if (fired & (1u << kHkSlot)) { slot_ = slot_ % kSlotCount + 1; d.action = SlotAction::NextSlot; }
    d.slot = slot_;
    const bool save = fired & (1u << kHkSave), load = fired & (1u << kHkLoad);
    if (!save && !load) return d;
    if (save && load) { d.action = SlotAction::Blocked; d.why = "save and load pressed together"; return d; }
    // Never in the middle of a voice exchange: a state taken (or restored) mid-listen leaves the game waiting
    // for a result that will never come.
    if (talk_held) { d.action = SlotAction::Blocked; d.why = "push-to-talk (Circle) is held"; return d; }
    if (voice_busy) { d.action = SlotAction::Blocked; d.why = "a voice command is being recognized"; return d; }
    if (in_flight) { d.action = SlotAction::Blocked; d.why = "the previous save/load is still running"; return d; }
    d.action = save ? SlotAction::Save : SlotAction::Load;
    return d;
}

std::string SaveSlots::state_path(int slot) const { return dir_ + "/slot" + std::to_string(slot) + ".state"; }
std::string SaveSlots::voice_path(int slot) const { return dir_ + "/slot" + std::to_string(slot) + ".voice"; }
std::string SaveSlots::backup_path() const { return dir_ + "/before-load.state"; }

bool save_slots_enabled(const char *env) { return env && env[0] == '1' && env[1] == 0; }
std::string save_dir(const char *env) {
    std::string d = env && *env ? env : "saves";
    while (d.size() > 1 && d.back() == '/') d.pop_back();
    return d;
}

LoadFollowUp after_load(SlotResult r) {
    LoadFollowUp f;
    if (r == SlotResult::Vetoed) return f;
    f.reset_voice = true;
    f.restore_backup = r == SlotResult::Failed;
    f.voice_from_slot = r == SlotResult::Ok;
    return f;
}

}  // namespace lifeline_input
