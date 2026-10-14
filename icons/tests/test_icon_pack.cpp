// Unit test for icon packs: c++ -std=c++20 -I.. ../icon_pack.cpp test_icon_pack.cpp && ./a.out
#include "icon_pack.hpp"
#include <cstdio>
#include <filesystem>
#include <fstream>
using namespace lifeline_icons;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++fails; } } while (0)

static std::string pam(unsigned w, unsigned h, const std::vector<std::uint8_t> &px) {
    return "P7\nWIDTH " + std::to_string(w) + "\nHEIGHT " + std::to_string(h) + "\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n" + std::string(px.begin(), px.end());
}
static std::string pgm(unsigned w, unsigned h, const std::vector<std::uint8_t> &px) {
    return "P5\n" + std::to_string(w) + " " + std::to_string(h) + "\n255\n" + std::string(px.begin(), px.end());
}

int main() {
    // filter: only small, known formats are ever hashed
    CHECK(wanted(kCT32, 64, 64) && wanted(kT4, 256, 256) && wanted(kT8, 8, 8));
    CHECK(!wanted(kCT32, 512, 64) && !wanted(kCT32, 64, 257) && !wanted(kCT32, 4, 64) && !wanted(0x1B, 64, 64));
    // hash covers format, size and pixels
    std::vector<std::uint8_t> a(64 * 4, 7);
    const auto h0 = upload_hash(kCT32, 8, 8, a.data(), a.size());
    CHECK(h0 == upload_hash(kCT32, 8, 8, a.data(), a.size()));
    CHECK(h0 != upload_hash(kCT32, 16, 4, a.data(), a.size()) && h0 != upload_hash(kT8, 8, 8, a.data(), a.size()));
    a[5] ^= 1; CHECK(h0 != upload_hash(kCT32, 8, 8, a.data(), a.size())); a[5] ^= 1;
    CHECK(hex(0x1234) == "0000000000001234");
    // images
    Image im; std::string e;
    CHECK(parse_image(pam(2, 1, {255, 0, 0, 255, 0, 0, 255, 0}), im, e) && im.channels == 4 && im.w == 2);
    CHECK(parse_image(pgm(2, 2, {1, 2, 3, 255}), im, e) && im.channels == 1 && im.px[3] == 255);
    CHECK(!parse_image("P6\n1 1\n255\nabc", im, e));
    CHECK(!parse_image(pgm(2, 2, {1, 2}), im, e));   // cut short
    // manifest lines
    ManifestLine m;
    CHECK(parse_manifest_line("00000000000000ff t8 256x64 3 4 a.pgm  # OPTION menu footer: Circle", m, e) && m.hash == 255 &&
          m.shape.psm == kT8 && m.shape.w == 256 && m.shape.h == 64 && m.x == 3 && m.y == 4 && m.file == "a.pgm");
    CHECK(parse_manifest_line("  # only a comment", m, e) && m.file.empty());
    CHECK(!parse_manifest_line("ff t8 256x64 3 4 a.pam", m, e));
    CHECK(!parse_manifest_line("00000000000000ff 3 4 a.pam", m, e));                    // old format (no psm / size)
    CHECK(!parse_manifest_line("00000000000000ff t9 256x64 3 4 a.pam", m, e));          // unknown psm
    CHECK(!parse_manifest_line("00000000000000ff t8 256x64x 3 4 a.pam", m, e));
    CHECK(!parse_manifest_line("00000000000000ff t8 512x64 3 4 a.pam", m, e));          // never hashed: too big
    CHECK(!parse_manifest_line("00000000000000ff t8 16x16 3 20 a.pam", m, e));          // y outside
    CHECK(!parse_manifest_line("00000000000000ff ct32 8x8 3 4 ../x.pam", m, e));
    CHECK(!parse_manifest_line("00000000000000ff ct32 8x8 3 4 a.pam extra", m, e));
    std::uint32_t ps = 0; CHECK(psm_from_name("ct16s", ps) && ps == kCT16S && !psm_from_name("x", ps));
    // apply: CT32, opaque red pixel + transparent pixel at (1,1) of an 8x8 texture
    Patch p; p.x = 1; p.y = 1; parse_image(pam(2, 1, {255, 0, 0, 255, 9, 9, 9, 0}), p.icon, e);
    std::vector<std::uint8_t> t(64 * 4, 0x10);
    CHECK(apply(p, kCT32, 8, 8, t.data(), t.size()));
    const std::size_t k = (1 * 8 + 1) * 4;
    CHECK(t[k] == 255 && t[k + 1] == 0 && t[k + 3] == 128 && t[k + 4] == 0x10 && t[k + 7] == 0x10 && t[0] == 0x10);
    Patch big = p; big.x = 7; CHECK(!apply(big, kCT32, 8, 8, t.data(), t.size()));   // off the edge: untouched
    CHECK(!apply(p, kT8, 8, 8, t.data(), 64));                                          // RGBA icon on paletted texture
    // CT16: red, alpha bit set
    std::vector<std::uint8_t> t16(64 * 2, 0);
    CHECK(apply(p, kCT16, 8, 8, t16.data(), t16.size()));
    const std::uint16_t v = static_cast<std::uint16_t>(t16[18] | t16[19] << 8); CHECK(v == (0x8000 | 31));
    // T8 / T4 indices, 255 keeps
    Patch q; q.x = 1; q.y = 0; parse_image(pgm(3, 1, {5, 255, 9}), q.icon, e);
    std::vector<std::uint8_t> t8(64, 1);
    CHECK(apply(q, kT8, 8, 8, t8.data(), t8.size()) && t8[1] == 5 && t8[2] == 1 && t8[3] == 9);
    std::vector<std::uint8_t> t4(32, 0x11);
    CHECK(apply(q, kT4, 8, 8, t4.data(), t4.size()) && t4[0] == 0x51 && t4[1] == 0x91);
    // pack loading + dump
    const auto dir = std::filesystem::temp_directory_path() / "lifeline_icon_test";
    std::filesystem::remove_all(dir); std::filesystem::create_directories(dir);
    std::ofstream(dir / "a.pam", std::ios::binary) << pam(2, 1, {255, 0, 0, 255, 9, 9, 9, 0});
    std::ofstream(dir / "icons.txt") << "# test\n00000000000000aa ct32 8x8 1 1 a.pam\n00000000000000aa ct32 8x8 4 4 a.pam\nzz ct32 8x8 1 1 a.pam\n"
                                          "00000000000000bb ct32 8x8 0 0 missing.pam\n00000000000000cc ct32 8x8 7 7 a.pam\n";
    Pack pk; e.clear();
    CHECK(load_pack(dir.string(), pk, e) && pk.patches.size() == 1 && pk.patches[0xaa].size() == 2 && e.find("zz") != std::string::npos &&
          e.find("missing") != std::string::npos && e.find("does not fit") != std::string::npos);
    // narrowed hashing: only the listed (psm, w, h) shapes
    CHECK(pk.shapes.size() == 1 && pk.wants(kCT32, 8, 8) && !pk.wants(kCT32, 8, 16) && !pk.wants(kT8, 8, 8));
    Pack none; e.clear(); CHECK(!load_pack((dir / "nope").string(), none, e));
    CHECK(dump(dir.string(), 0xaa, kT4, 8, 8, t4.data(), t4.size()) && std::filesystem::exists(dir / "00000000000000aa_8x8_t4.pgm"));
    Image d4; CHECK(load_image((dir / "00000000000000aa_8x8_t4.pgm").string(), d4, e) && d4.px[0] == 1 && d4.px[1] == 5 && d4.px[2] == 1 && d4.px[3] == 9);   // raw indices
    CHECK(dump(dir.string(), 0xab, kCT32, 8, 8, t.data(), t.size()));
    Image back; CHECK(load_image((dir / "00000000000000ab_8x8_ct32.pam").string(), back, e) && back.px[k] == 255 && back.px[k + 3] == 255);
    std::filesystem::remove_all(dir);
    // shipped packs parse
    for (const char *pack : {"../packs/xbox", "../packs/deck"}) { Pack s; std::string err; CHECK(load_pack(pack, s, err) && err.empty() && s.patches.size() == 2 && s.shapes.size() == 1 && s.wants(kT8, 256, 64)); }
    std::printf(fails ? "%d FAILED\n" : "all icon pack tests passed\n", fails);
    return fails != 0;
}
