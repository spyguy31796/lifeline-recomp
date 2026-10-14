// Lifeline Recomp: icon pack logic (see icon_pack.hpp).
#include "icon_pack.hpp"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>

namespace lifeline_icons {

namespace {
std::uint32_t bpp(std::uint32_t psm) {
    switch (psm) { case kCT32: return 32; case kCT24: return 24; case kCT16: case kCT16S: return 16; case kT8: return 8; case kT4: return 4; }
    return 0;
}
bool indexed(std::uint32_t psm) { return psm == kT8 || psm == kT4; }
std::size_t need(std::uint32_t psm, std::uint32_t w, std::uint32_t h) { return (static_cast<std::size_t>(w) * h * bpp(psm) + 7) / 8; }
}  // namespace

bool wanted(std::uint32_t psm, std::uint32_t w, std::uint32_t h) {
    return bpp(psm) && w >= 8 && h >= 8 && w <= kMaxSide && h <= kMaxSide;
}

std::uint64_t upload_hash(std::uint32_t psm, std::uint32_t w, std::uint32_t h, const std::uint8_t *data, std::size_t bytes) {
    std::uint64_t x = 1469598103934665603ull;
    auto mix = [&](std::uint8_t b) { x ^= b; x *= 1099511628211ull; };
    for (std::uint32_t v : {psm, w, h}) for (int i = 0; i < 4; ++i) mix(static_cast<std::uint8_t>(v >> (8 * i)));
    for (std::size_t i = 0; i < bytes; ++i) mix(data[i]);
    return x;
}

std::string hex(std::uint64_t h) { char b[17]; std::snprintf(b, sizeof b, "%016llx", static_cast<unsigned long long>(h)); return b; }

const char *psm_name(std::uint32_t psm) {
    switch (psm) { case kCT32: return "ct32"; case kCT24: return "ct24"; case kCT16: return "ct16"; case kCT16S: return "ct16s"; case kT8: return "t8"; case kT4: return "t4"; }
    return "other";
}

bool parse_image(const std::string &b, Image &out, std::string &err) {
    std::istringstream in(b);
    std::string magic; in >> magic;
    out = Image{};
    if (magic == "P5") {
        unsigned maxv = 0; in >> out.w >> out.h >> maxv; in.get();
        if (!in || maxv != 255) { err = "bad PGM header"; return false; }
        out.channels = 1;
    } else if (magic == "P7") {
        std::string k, tupl; unsigned depth = 0, maxv = 0;
        while (in >> k && k != "ENDHDR") {
            if (k == "WIDTH") in >> out.w; else if (k == "HEIGHT") in >> out.h; else if (k == "DEPTH") in >> depth;
            else if (k == "MAXVAL") in >> maxv; else if (k == "TUPLTYPE") in >> tupl;
            else if (k[0] == '#') { std::string rest; std::getline(in, rest); }
        }
        in.get();
        if (depth != 4 || maxv != 255 || tupl != "RGB_ALPHA") { err = "PAM must be RGB_ALPHA, depth 4, maxval 255"; return false; }
        out.channels = 4;
    } else { err = "not a PGM (P5) or PAM (P7) file"; return false; }
    if (!out.w || !out.h || out.w > kMaxSide || out.h > kMaxSide) { err = "bad image size"; return false; }
    const std::size_t n = static_cast<std::size_t>(out.w) * out.h * out.channels;
    out.px.resize(n);
    in.read(reinterpret_cast<char *>(out.px.data()), static_cast<std::streamsize>(n));
    if (static_cast<std::size_t>(in.gcount()) != n) { err = "image data cut short"; return false; }
    return true;
}

bool load_image(const std::string &path, Image &out, std::string &err) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { err = "cannot open " + path; return false; }
    std::stringstream ss; ss << f.rdbuf();
    if (!parse_image(ss.str(), out, err)) { err = path + ": " + err; return false; }
    return true;
}

bool psm_from_name(const std::string &n, std::uint32_t &psm) {
    for (std::uint32_t v : {kCT32, kCT24, kCT16, kCT16S, kT8, kT4})
        if (n == psm_name(v)) { psm = v; return true; }
    return false;
}

bool parse_manifest_line(const std::string &line0, ManifestLine &o, std::string &err) {
    o = ManifestLine{};
    std::string line = line0.substr(0, line0.find('#'));
    std::istringstream in(line);
    std::string hs, ps, wh;
    if (!(in >> hs)) return true;   // blank / comment
    auto bad = [&](const std::string &why) {
        err = "bad manifest line '" + line0 + "' (" + why + "; want: <16 hex> <psm> <w>x<h> <x> <y> <icon file>)"; o.file.clear(); return false;
    };
    long long xx = -1, yy = -1;
    if (hs.size() != 16 || hs.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos) return bad("hash");
    if (!(in >> ps >> wh >> xx >> yy >> o.file)) return bad("missing field");
    if (!psm_from_name(ps, o.shape.psm)) return bad("unknown psm '" + ps + "'");
    unsigned w = 0, h = 0; char xch = 0, extra_c = 0;
    if (std::sscanf(wh.c_str(), "%u%c%u%c", &w, &xch, &h, &extra_c) != 3 || xch != 'x' || !wanted(o.shape.psm, w, h)) return bad("size '" + wh + "'");
    o.shape.w = w; o.shape.h = h;
    if (xx < 0 || yy < 0 || xx >= w || yy >= h) return bad("x/y outside the texture");
    std::string extra;
    if (in >> extra) return bad("extra text");
    if (o.file.find("..") != std::string::npos || o.file[0] == '/') { err = "icon path must stay in the pack: " + o.file; o.file.clear(); return false; }
    o.hash = std::stoull(hs, nullptr, 16); o.x = static_cast<std::uint32_t>(xx); o.y = static_cast<std::uint32_t>(yy);
    return true;
}

bool load_pack(const std::string &dir, Pack &out, std::string &err) {
    std::ifstream f(dir + "/icons.txt");
    if (!f) { err = "no " + dir + "/icons.txt"; return false; }
    std::map<std::string, Image> cache;
    for (std::string line; std::getline(f, line);) {
        ManifestLine m; std::string e;
        if (!parse_manifest_line(line, m, e)) { err += e + "; "; continue; }
        if (m.file.empty()) continue;
        auto it = cache.find(m.file);
        if (it == cache.end()) {
            Image im;
            if (!load_image(dir + "/" + m.file, im, e)) { err += e + "; "; continue; }
            it = cache.emplace(m.file, std::move(im)).first;
        }
        if (m.x + it->second.w > m.shape.w || m.y + it->second.h > m.shape.h) { err += m.file + " does not fit " + hex(m.hash) + "; "; continue; }
        out.patches[m.hash].push_back(Patch{m.x, m.y, it->second, m.file});
        out.shapes.insert(m.shape);
    }
    return true;
}

bool apply(const Patch &p, std::uint32_t psm, std::uint32_t w, std::uint32_t h, std::uint8_t *d, std::size_t bytes) {
    const Image &im = p.icon;
    if (!bpp(psm) || bytes < need(psm, w, h) || p.x + im.w > w || p.y + im.h > h) return false;
    if (indexed(psm) != (im.channels == 1)) return false;
    for (std::uint32_t iy = 0; iy < im.h; ++iy)
        for (std::uint32_t ix = 0; ix < im.w; ++ix) {
            const std::size_t i = static_cast<std::size_t>(p.y + iy) * w + (p.x + ix);
            const std::uint8_t *s = &im.px[(static_cast<std::size_t>(iy) * im.w + ix) * im.channels];
            if (im.channels == 1) {
                if (s[0] == 255) continue;
                if (psm == kT8) d[i] = s[0];
                else { std::uint8_t &b = d[i / 2]; const std::uint8_t v = s[0] & 15u; b = (i & 1) ? static_cast<std::uint8_t>((b & 0x0F) | (v << 4)) : static_cast<std::uint8_t>((b & 0xF0) | v); }
                continue;
            }
            const unsigned a = s[3];
            if (!a) continue;
            auto mixc = [a](unsigned src, unsigned dst) { return static_cast<std::uint8_t>((src * a + dst * (255 - a) + 127) / 255); };
            if (psm == kCT32 || psm == kCT24) {
                const std::size_t k = i * (psm == kCT32 ? 4 : 3);
                for (int c = 0; c < 3; ++c) d[k + c] = mixc(s[c], d[k + c]);
                if (psm == kCT32) d[k + 3] = static_cast<std::uint8_t>(std::max<unsigned>(d[k + 3], (a + 1) / 2));   // PS2 alpha: 0x80 = opaque
            } else {
                std::uint16_t v; std::memcpy(&v, d + i * 2, 2);
                const unsigned r = (v & 31u) << 3, g = ((v >> 5) & 31u) << 3, b = ((v >> 10) & 31u) << 3;
                v = static_cast<std::uint16_t>((mixc(s[0], r) >> 3) | ((mixc(s[1], g) >> 3) << 5) | ((mixc(s[2], b) >> 3) << 10) | (a >= 128 || (v & 0x8000u) ? 0x8000u : 0u));
                std::memcpy(d + i * 2, &v, 2);
            }
        }
    return true;
}

bool dump(const std::string &dir, std::uint64_t hash, std::uint32_t psm, std::uint32_t w, std::uint32_t h, const std::uint8_t *d, std::size_t bytes) {
    if (!bpp(psm) || bytes < need(psm, w, h)) return false;
    const std::string base = dir + "/" + hex(hash) + "_" + std::to_string(w) + "x" + std::to_string(h) + "_" + psm_name(psm);
    std::ofstream f(base + (indexed(psm) ? ".pgm" : ".pam"), std::ios::binary);
    if (!f) return false;
    if (indexed(psm)) {
        f << "P5\n" << w << " " << h << "\n255\n";
        for (std::size_t i = 0; i < static_cast<std::size_t>(w) * h; ++i)
            f.put(static_cast<char>(psm == kT8 ? d[i] : (d[i / 2] >> ((i & 1) * 4)) & 15u));   // raw palette indices (T4: 0-15, so it looks dark)
    } else {
        f << "P7\nWIDTH " << w << "\nHEIGHT " << h << "\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n";
        for (std::size_t i = 0; i < static_cast<std::size_t>(w) * h; ++i) {
            std::uint8_t px[4] = {0, 0, 0, 255};
            if (psm == kCT32) { std::memcpy(px, d + i * 4, 4); px[3] = static_cast<std::uint8_t>(std::min(255, px[3] * 2)); }
            else if (psm == kCT24) std::memcpy(px, d + i * 3, 3);
            else { std::uint16_t v; std::memcpy(&v, d + i * 2, 2); px[0] = (v & 31u) << 3; px[1] = ((v >> 5) & 31u) << 3; px[2] = ((v >> 10) & 31u) << 3; px[3] = (v & 0x8000u) ? 255 : 0; }
            f.write(reinterpret_cast<const char *>(px), 4);
        }
    }
    return static_cast<bool>(f);
}

}  // namespace lifeline_icons
