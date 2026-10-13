// Tolerant matcher for natural command sentences ("please walk over to the front door") against a context's VGP
// phrase table. Generic English only: filler words are ignored, verbs are folded into synonym groups,
// object words match fuzzily (plural, one-edit typos, homophones). Nothing game-specific lives here.
#pragma once
#include <string>
#include <vector>
namespace voice {
struct SlotPhrase { std::string vgp; int cls = 0; std::vector<std::string> toks; };  // toks = spoken form tokens
class SlotMatcher {
public:
    void build(const std::vector<std::string> &vgp, const std::vector<int> &cls);
    // Exact VGP strings to deliver (one per class slot, in spoken order), or empty = reject.
    // `why` gets a short reason for the log.
    std::vector<std::string> match(const std::string &raw, std::string *why = nullptr) const;
    // Extra single words worth adding to the recognizer grammar (fillers + synonyms of verbs in this table).
    std::vector<std::string> grammar_words() const;
    static bool is_filler(const std::string &w);
private:
    std::vector<SlotPhrase> ph_;
};
}
