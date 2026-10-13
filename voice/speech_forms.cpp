#include "speech_forms.hpp"
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
namespace voice {
std::string normalize_phrase(const std::string &s) {
    std::string o;
    for (char c : s) {
        unsigned char u = static_cast<unsigned char>(c);
        if (u >= 'A' && u <= 'Z') u = u - 'A' + 'a';
        if ((u >= 'a' && u <= 'z') || (u >= '0' && u <= '9') || u == '\'') o.push_back(char(u));
        else if (!o.empty() && o.back() != ' ') o.push_back(' ');
    }
    while (!o.empty() && o.back() == ' ') o.pop_back();
    return o;
}
namespace {
const char *kOnes[] = {"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                       "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"};
const char *kTens[] = {"", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"};
std::string below100(unsigned n) {
    if (n < 20) return kOnes[n];
    return std::string(kTens[n / 10]) + (n % 10 ? std::string(" ") + kOnes[n % 10] : "");
}
// Spoken-form aliases for words the model does not know. Nothing is built in: the table is generated
// locally by tools/build_aliases.py from the user's own extracted phrase tables and loaded at run time.
std::map<std::string, std::string> &aliases() { static std::map<std::string, std::string> m; return m; }
// Generic English contractions the model may lack as single words ("they're" -> "they are").
std::string expand_contraction(const std::string &t) {
    static const std::pair<const char *, const char *> rules[] = {{"'re", " are"}, {"'ve", " have"}, {"'ll", " will"}, {"'m", " them"}};
    if (t.size() > 3 && t.compare(t.size() - 3, 3, "in'") == 0) return t.substr(0, t.size() - 1) + "g";  // goin' -> going
    if (t == "i'm") return t;
    for (const auto &[suf, rep] : rules) {
        const std::string sf = suf;
        if (t.size() > sf.size() + 1 && t.compare(t.size() - sf.size(), sf.size(), sf) == 0) return t.substr(0, t.size() - sf.size()) + rep;
    }
    return t;
}
// Homophones a recognizer may return for a word (both directions are folded by homophone_key).
const std::map<std::string, std::vector<std::string>> &homophones() {
    static const std::map<std::string, std::vector<std::string>> m = {
        {"two", {"to", "too"}}, {"four", {"for"}}, {"eight", {"ate"}}, {"one", {"won"}},
    };
    return m;
}
}
std::string number_words(unsigned n) {
    if (n < 100) return below100(n);
    if (n < 1000) return std::string(kOnes[n / 100]) + " hundred" + (n % 100 ? " " + below100(n % 100) : "");
    if (n >= 1100 && n < 2000 && n % 100) return below100(n / 100) + " " + (n % 100 < 10 ? "oh " : "") + below100(n % 100);  // years
    if (n < 10000) return std::string(kOnes[n / 1000]) + " thousand" + (n % 1000 ? " " + number_words(n % 1000) : "");
    return {};
}
std::vector<std::string> spoken_forms(const std::string &p) {
    for (unsigned char c : p) if (c >= 0x80) return {};
    std::istringstream in(normalize_phrase(p));
    std::vector<std::vector<std::string>> slots;  // per token: alternatives (first = primary)
    for (std::string t; in >> t;) {
        // A word with trailing digits (e.g. "word2") is a VoCon variant marker; the digits are not spoken.
        if (std::isalpha(static_cast<unsigned char>(t[0])) && std::isdigit(static_cast<unsigned char>(t.back()))) {
            while (!t.empty() && std::isdigit(static_cast<unsigned char>(t.back()))) t.pop_back();
        }
        std::string w = t, alt_form;
        if (!t.empty() && t.find_first_not_of("0123456789") == std::string::npos) {
            w = t.size() <= 4 ? number_words(static_cast<unsigned>(std::stoul(t))) : t;
        } else if (auto a = aliases().find(t); a != aliases().end()) {
            w = a->second;
        } else if (const std::string c = expand_contraction(t); c != t) {
            alt_form = c;  // keep the original spelling as primary, add the expansion as a variant
        }
        std::istringstream ws(w);
        std::vector<std::string> parts;
        for (std::string x; ws >> x;) parts.push_back(x);
        for (std::size_t k = 0; k < parts.size(); ++k) {
            std::vector<std::string> alt{parts[k]};
            if (auto h = homophones().find(parts[k]); h != homophones().end()) alt.insert(alt.end(), h->second.begin(), h->second.end());
            if (!alt_form.empty() && parts.size() == 1) alt.push_back(alt_form);
            slots.push_back(std::move(alt));
        }
    }
    if (slots.empty() || (slots.size() == 1 && slots[0][0] == "dummy")) return {};
    std::vector<std::string> out{""};
    for (const auto &s : slots) {
        std::vector<std::string> next;
        for (const auto &o : out)
            for (std::size_t i = 0; i < s.size(); ++i) {
                if (i > 0 && next.size() >= 16) break;  // cap variant explosion; primary always kept
                next.push_back(o.empty() ? s[i] : o + " " + s[i]);
            }
        out.swap(next);
    }
    return out;
}
std::string homophone_key(const std::string &spoken) {
    static std::map<std::string, std::string> fold;
    if (fold.empty())
        for (const auto &[canon, alts] : homophones()) for (const auto &a : alts) fold[a] = canon;
    std::istringstream in(spoken);
    std::string o;
    for (std::string t; in >> t;) {
        if (auto f = fold.find(t); f != fold.end()) t = f->second;
        o += (o.empty() ? "" : " ") + t;
    }
    return o;
}
std::size_t load_aliases() {
    aliases().clear();
    std::vector<std::string> files;
    if (const char *f = std::getenv("PS2_VOICE_ALIASES")) files.push_back(f);
    else if (const char *d = std::getenv("PS2_VOICE_ASSETS")) files.push_back(std::string(d) + "/aliases.tsv");
    if (const char *d = std::getenv("PS2_VOICE_ASSETS")) files.push_back(std::string(d) + "/aliases.local.tsv");  // user fixes win
    for (const auto &path : files) {
        std::ifstream in(path);
        std::size_t n = 0;
        for (std::string line; std::getline(in, line);) {
            if (line.empty() || line[0] == '#') continue;
            const auto t1 = line.find('\t'); if (t1 == std::string::npos) continue;
            const auto t2 = line.find('\t', t1 + 1);
            const std::string key = normalize_phrase(line.substr(0, t1));
            const std::string val = normalize_phrase(line.substr(t1 + 1, t2 == std::string::npos ? std::string::npos : t2 - t1 - 1));
            if (!key.empty() && !val.empty()) { aliases()[key] = val; ++n; }
        }
        if (in.is_open() || n) std::fprintf(stderr, "[voice] %zu aliases from %s\n", n, path.c_str());
    }
    return aliases().size();
}
}
