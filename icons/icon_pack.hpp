// Lifeline Recomp: in-game button icon replacement (our code, MIT). SDL- and runtime-free for unit tests.
// The runner hands us each small host->GS texture upload (patch 0008). We hash it (FNV-1a 64 over format, size and
// pixels). A pack's icons.txt says which uploads to patch and where:
//     <hash, 16 hex> <psm> <w>x<h> <x> <y> <icon file>    # comment
// psm and WxH are what PS2_TEX_DUMP's uploads.txt prints (psm names: ct32 ct24 ct16 ct16s t8 t4). With a pack set,
// only uploads of a listed (psm, w, h) are gathered and hashed at all.
// The icon is our own art. RGBA textures (PSMCT32/24/16) take a PAM (P7, RGB_ALPHA) icon that is composited over
// the original. Paletted textures (PSMT8/PSMT4) take a PGM (P5) of palette indices, where 255 keeps the original
// pixel. Hashes are derived from the disc but contain no pixels, so a manifest can be shared; dumps can't.
#pragma once
#include <cstddef>
#include <cstdint>
#include <map>
#include <set>
#include <tuple>
#include <string>
#include <vector>

namespace lifeline_icons {

enum Psm : std::uint32_t { kCT32 = 0x00, kCT24 = 0x01, kCT16 = 0x02, kCT16S = 0x0A, kT8 = 0x13, kT4 = 0x14 };
constexpr std::uint32_t kMaxSide = 256;   // glyph atlases are small; bigger uploads are never hashed (perf)

bool wanted(std::uint32_t psm, std::uint32_t w, std::uint32_t h);   // format + size filter, before any hashing
std::uint64_t upload_hash(std::uint32_t psm, std::uint32_t w, std::uint32_t h, const std::uint8_t *data, std::size_t bytes);
std::string hex(std::uint64_t h);
const char *psm_name(std::uint32_t psm);
bool psm_from_name(const std::string &name, std::uint32_t &psm);

struct Image {            // PAM RGBA (channels 4) or PGM indices (channels 1)
    std::uint32_t w = 0, h = 0, channels = 0;
    std::vector<std::uint8_t> px;
};
bool load_image(const std::string &path, Image &out, std::string &err);
bool parse_image(const std::string &bytes, Image &out, std::string &err);

struct Patch { std::uint32_t x = 0, y = 0; Image icon; std::string file; };
struct Shape {
    std::uint32_t psm = 0, w = 0, h = 0;
    bool operator<(const Shape &o) const { return std::tie(psm, w, h) < std::tie(o.psm, o.w, o.h); }
};
struct Pack {
    std::map<std::uint64_t, std::vector<Patch>> patches;
    std::set<Shape> shapes;   // (psm, w, h) of every listed upload: the only ones worth hashing
    bool wants(std::uint32_t psm, std::uint32_t w, std::uint32_t h) const { return shapes.count(Shape{psm, w, h}) > 0; }
};
struct ManifestLine {
    std::uint64_t hash = 0;
    Shape shape;
    std::uint32_t x = 0, y = 0;
    std::string file;   // empty: blank or comment line
};
// dir/icons.txt; bad lines are reported in err and skipped. Returns false if the manifest is missing.
bool load_pack(const std::string &dir, Pack &out, std::string &err);
bool parse_manifest_line(const std::string &line, ManifestLine &out, std::string &err);

// Draws p.icon at (p.x, p.y) into a linear upload of format psm. Returns false (data untouched) if the icon kind
// doesn't fit the format or the rect is outside the texture.
bool apply(const Patch &p, std::uint32_t psm, std::uint32_t w, std::uint32_t h, std::uint8_t *data, std::size_t bytes);

// Dump an upload as a viewable file (PAM for RGBA formats, PGM of indices for paletted); local authoring only.
bool dump(const std::string &dir, std::uint64_t hash, std::uint32_t psm, std::uint32_t w, std::uint32_t h, const std::uint8_t *data, std::size_t bytes);

}  // namespace lifeline_icons
