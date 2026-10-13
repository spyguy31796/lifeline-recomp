// Maps game VGP phrase strings to the forms a speech recognizer can actually produce, and back.
// VGP phrases are VoCon spellings: digits, run-together or phonetic respellings, contractions and
// punctuation. Vosk only emits lowercase dictionary words, so each phrase gets
// one or more spoken forms, and recognized text is mapped back to the exact VGP string.
#pragma once
#include <cstddef>
#include <string>
#include <vector>
namespace voice {
// Lowercase, keep [a-z0-9'], collapse everything else to single spaces.
std::string normalize_phrase(const std::string &s);
// Integer 0..9999 in words ("1976" -> "nineteen seventy six"). Empty if out of range.
std::string number_words(unsigned n);
// Spoken forms for a VGP phrase: the primary form first, then homophone variants (e.g. "gate two",
// "gate to", "gate too"). Empty if the phrase is not speakable (non-ASCII system token, dummy).
std::vector<std::string> spoken_forms(const std::string &vgp_phrase);
// Load spoken-form aliases (token<TAB>spoken words) from $PS2_VOICE_ALIASES, else $PS2_VOICE_ASSETS/aliases.tsv,
// then $PS2_VOICE_ASSETS/aliases.local.tsv (overrides). Generate them with tools/build_aliases.py. Returns the count.
std::size_t load_aliases();
// Folds homophones to one spelling (to/too -> two, for -> four, ...) for a lenient second-chance lookup.
std::string homophone_key(const std::string &spoken);
}
