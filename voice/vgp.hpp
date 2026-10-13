// Parser for the game's VGP phrase table, read from guest memory at run time.
#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
namespace voice {
struct VgpEntry { std::int16_t clsid, wordid; std::string phrase; };
struct Vgp {
    std::uint32_t base = 0;
    std::vector<VgpEntry> entries;
    const VgpEntry *find(const std::string &phrase) const;
};
// Parse a "VGP 2.00" blob that starts at guest address `base`. Returns nullopt if not a VGP.
std::optional<Vgp> parse_vgp(std::uint32_t base);
// Same, from a host buffer (e.g. the user's own extracted .vgp file for the active context).
std::optional<Vgp> parse_vgp_bytes(const std::vector<std::uint8_t> &b);
}
