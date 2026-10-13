#include "slot_match.hpp"
#include "speech_forms.hpp"
#include <algorithm>
#include <map>
#include <set>
#include <sstream>
namespace voice {
namespace {
// Words that carry no command meaning in a spoken request.
const std::set<std::string> kFiller = {
    "to", "the", "a", "an", "over", "please", "can", "could", "would", "will", "you", "let's", "lets", "us",
    "now", "there", "that", "this", "my", "your", "up", "on", "at", "into", "in", "toward", "towards", "onto",
    "and", "then", "just", "okay", "ok", "hey", "for", "me", "by", "of", "some"};
// Generic English verb synonym groups; each word maps to its group's first word.
const std::vector<std::vector<std::string>> kSyn = {
    {"walk", "go", "move", "head", "come", "proceed", "step", "get", "approach", "travel"},
    {"look", "check", "examine", "inspect", "search", "see", "investigate", "observe"},
    {"take", "pick", "grab", "collect", "get"},
    {"open", "unlock"},
    {"close", "shut"},
    {"use", "operate", "activate"},
    {"talk", "speak", "chat", "ask"},
    {"stop", "wait", "halt", "freeze", "stay"},
    {"run", "dash", "sprint", "rush"},
    {"leave", "exit"},
    {"push", "press"},
    {"sit", "rest"},
};
// Common verbs with no group above. They are added to the grammar so that an off-context command decodes as
// itself (and is rejected as unexplained) instead of being forced onto a similar-sounding in-context word.
const std::vector<std::string> kOtherVerbs = {"throw", "eat", "kill", "jump", "climb", "break", "kick", "drink",
    "give", "read", "turn", "pull", "sleep", "fight", "hit", "shoot", "hide", "call", "touch", "follow", "find"};
const std::map<std::string, std::string> &syn() {
    static std::map<std::string, std::string> m;
    if (m.empty())
        for (const auto &g : kSyn) for (const auto &w : g) m.emplace(w, g[0]);  // first group wins for shared words
    return m;
}
std::string canon(std::string w) {
    w = homophone_key(w);
    if (auto it = syn().find(w); it != syn().end()) return it->second;
    if (w.size() >= 5 && w.compare(w.size() - 3, 3, "ing") == 0)  // going, heading, walking
        if (auto it = syn().find(w.substr(0, w.size() - 3)); it != syn().end()) return it->second;
    return w;
}
std::string stem(const std::string &w) {  // crude plural fold
    if (w.size() > 4 && w.compare(w.size() - 3, 3, "ies") == 0) return w.substr(0, w.size() - 3) + "y";
    if (w.size() > 3 && w.back() == 's' && w[w.size() - 2] != 's') return w.substr(0, w.size() - 1);
    return w;
}
bool near1(const std::string &a, const std::string &b) {  // edit distance <= 1
    if (a == b) return true;
    if (a.size() < 5 || b.size() < 5) return false;
    const std::string &s = a.size() <= b.size() ? a : b, &l = a.size() <= b.size() ? b : a;
    if (l.size() - s.size() > 1) return false;
    std::size_t i = 0, j = 0, e = 0;
    while (i < s.size() && j < l.size()) {
        if (s[i] == l[j]) { ++i; ++j; continue; }
        if (++e > 1) return false;
        if (s.size() == l.size()) ++i;
        ++j;
    }
    return e + (l.size() - j) + (s.size() - i) <= 1;
}
bool tok_eq(const std::string &u, const std::string &p) {
    const std::string a = canon(u), b = canon(p);
    return a == b || stem(a) == stem(b) || near1(stem(a), stem(b));
}
std::vector<std::string> content(const std::vector<std::string> &t) {
    std::vector<std::string> c;
    for (const auto &w : t) if (!SlotMatcher::is_filler(w)) c.push_back(w);
    return c.empty() ? t : c;  // a phrase made only of fillers keeps its words ("go to")
}
}
bool SlotMatcher::is_filler(const std::string &w) { return kFiller.count(w) > 0; }

void SlotMatcher::build(const std::vector<std::string> &vgp, const std::vector<int> &cls) {
    ph_.clear();
    for (std::size_t i = 0; i < vgp.size(); ++i) {
        const auto forms = spoken_forms(vgp[i]);
        if (forms.empty()) continue;
        SlotPhrase p; p.vgp = vgp[i]; p.cls = i < cls.size() ? cls[i] : 0;
        std::istringstream in(forms[0]);
        for (std::string w; in >> w;) p.toks.push_back(w);
        p.toks = content(p.toks);
        ph_.push_back(std::move(p));
    }
}

std::vector<std::string> SlotMatcher::grammar_words() const {
    std::vector<std::string> out(kFiller.begin(), kFiller.end());
    for (const auto &g : kSyn) out.insert(out.end(), g.begin(), g.end());
    out.insert(out.end(), kOtherVerbs.begin(), kOtherVerbs.end());
    for (const auto &p : ph_) {  // singular / plural of each phrase's last word ("box" for "boxes")
        const std::string &w = p.toks.back();
        if (w.size() < 4 || !std::all_of(w.begin(), w.end(), [](char c) { return c >= 'a' && c <= 'z'; })) continue;
        out.push_back(stem(w) != w ? stem(w) : w + "s");
    }
    std::sort(out.begin(), out.end()); out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

std::vector<std::string> SlotMatcher::match(const std::string &raw, std::string *why) const {
    auto fail = [&](const char *r) { if (why) *why = r; return std::vector<std::string>{}; };
    std::vector<std::string> u;
    int unk = 0;
    { std::istringstream in(raw); for (std::string w; in >> w;) { if (w == "[unk]") ++unk; else if (!is_filler(w)) u.push_back(w); } }
    if (u.empty()) return fail("no content words");
    // Score each phrase: fraction of its content tokens found in the utterance; remember which tokens it used.
    struct Cand { const SlotPhrase *p; double score; std::vector<bool> used; std::size_t first; int missing; };
    std::vector<Cand> cands;
    for (const auto &p : ph_) {
        Cand c{&p, 0, std::vector<bool>(u.size(), false), u.size(), 0};
        int hit = 0;
        for (const auto &t : p.toks) {
            bool f = false;
            for (std::size_t k = 0; k < u.size() && !f; ++k)
                if (!c.used[k] && tok_eq(u[k], t)) { c.used[k] = true; f = true; ++hit; c.first = std::min(c.first, k); }
            if (!f) ++c.missing;
        }
        if (!hit) continue;
        c.score = double(hit) / p.toks.size();
        // A partial phrase must at least start right ("front" for "front door", not "house" for "leave the house").
        bool head = false;
        for (std::size_t k = 0; k < u.size(); ++k) head |= c.used[k] && tok_eq(u[k], p.toks[0]);
        if (c.score >= 0.5 && (c.missing == 0 || head)) cands.push_back(std::move(c));
    }
    if (cands.empty()) return fail("no phrase overlaps");
    // Pick at most one phrase per class, greedily by (tokens covered, score), without reusing utterance tokens.
    std::sort(cands.begin(), cands.end(), [](const Cand &a, const Cand &b) {
        const auto na = std::count(a.used.begin(), a.used.end(), true), nb = std::count(b.used.begin(), b.used.end(), true);
        if (na != nb) return na > nb;
        if (a.score != b.score) return a.score > b.score;
        return a.p->toks.size() < b.p->toks.size();
    });
    std::vector<bool> cover(u.size(), false);
    std::set<int> classes;
    std::vector<const Cand *> pick;
    int missing = 0;
    for (const auto &c : cands) {
        if (classes.count(c.p->cls)) continue;
        bool clash = false;
        for (std::size_t k = 0; k < u.size(); ++k) clash |= c.used[k] && cover[k];
        if (clash) continue;
        for (std::size_t k = 0; k < u.size(); ++k) cover[k] = cover[k] || c.used[k];
        classes.insert(c.p->cls); pick.push_back(&c); missing += c.missing;
    }
    const auto uncovered = std::count(cover.begin(), cover.end(), false);
    bool full = false;
    for (const auto *c : pick) full |= c->missing == 0;
    if (!full) return fail("only partial phrases");
    if (uncovered) return fail("unexplained words");
    if (unk > missing) return fail("unrecognized speech");       // [unk] may only stand in for a phrase's missing word
    std::sort(pick.begin(), pick.end(), [](const Cand *a, const Cand *b) { return a->first < b->first; });
    for (std::size_t i = 0; i + 1 < pick.size(); ++i)  // only the last phrase spoken may trail off ("walk save ...")
        if (pick[i]->missing) return fail("partial phrase mid-sentence");
    std::vector<std::string> out;
    for (const auto *c : pick) out.push_back(c->p->vgp);
    if (why) *why = "fuzzy";
    return out;
}
}
