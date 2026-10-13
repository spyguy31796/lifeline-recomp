#include "vgp.hpp"
#include "ps2/memory.hpp"
#include <functional>
namespace voice {
const VgpEntry *Vgp::find(const std::string &p) const {
    for (const auto &e : entries) if (e.phrase == p) return &e;
    return nullptr;
}
namespace {
using Rd8 = std::function<std::uint8_t(std::uint32_t)>;
std::uint16_t r16(const Rd8 &r, std::uint32_t a) { return std::uint16_t(r(a) | r(a + 1) << 8); }
std::uint32_t r32(const Rd8 &r, std::uint32_t a) { return r16(r, a) | std::uint32_t(r16(r, a + 2)) << 16; }
std::string rstr(const Rd8 &r, std::uint32_t a, std::size_t max) {
    std::string s;
    for (std::size_t i = 0; i < max; ++i) { char ch = static_cast<char>(r(a + i)); if (!ch) break; s.push_back(ch); }
    return s;
}
std::optional<Vgp> parse(const Rd8 &r, std::uint32_t base, std::uint32_t limit) {
    if (limit < 0x20 || rstr(r, base, 4) != "VGP ") return std::nullopt;
    const std::uint32_t str_end = r32(r, base + 12), first = r32(r, base + 0x18);
    if (first < 0x20 || first > str_end || str_end > 0x100000 || str_end > limit) return std::nullopt;
    Vgp v; v.base = base;
    for (std::uint32_t o = 0x10; o + 16 <= first; o += 16) {
        VgpEntry e;
        e.clsid = static_cast<std::int16_t>(r16(r, base + o));
        e.wordid = static_cast<std::int16_t>(r16(r, base + o + 2));
        const std::uint32_t len8 = r16(r, base + o + 4), off = r32(r, base + o + 8);
        if (off >= limit) return std::nullopt;
        e.phrase = rstr(r, base + off, std::min<std::size_t>(len8 * 8, limit - off));
        v.entries.push_back(std::move(e));
    }
    return v;
}
}
std::optional<Vgp> parse_vgp(std::uint32_t base) {
    return parse([](std::uint32_t a) { return ps2::ld8(a); }, base, 0x100000);
}
std::optional<Vgp> parse_vgp_bytes(const std::vector<std::uint8_t> &b) {
    return parse([&](std::uint32_t a) -> std::uint8_t { return a < b.size() ? b[a] : 0; }, 0, static_cast<std::uint32_t>(b.size()));
}
}
