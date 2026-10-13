// PS2_VOICE_DEBUG=1: one line per recognition to PS2_VOICE_LOG (default ./voice.log).
#pragma once
#include <string>
namespace voice {
bool debug_enabled();
void debug_log(const std::string &line);
}
