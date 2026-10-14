// Lifeline Recomp: runner side of the icon packs (texture upload hook from patch 0008).
//   PS2_ICON_PACK=<dir>   patch uploads listed in <dir>/icons.txt (run.sh sets it from [qol] button_icons)
//   PS2_TEX_DUMP=<dir>    write every new small upload to <dir> (authoring; game-derived, never share)
// Both unset: lifeline_gs_upload_enabled() is false and the runner never gathers or hashes anything.
#include "icon_pack.hpp"
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <unordered_set>

using namespace lifeline_icons;

namespace {
struct Hook {
    bool on = false;
    std::string dump_dir;
    Pack pack;
    std::unordered_set<std::uint64_t> seen;
    std::uint64_t patched = 0;
    Hook() {
        if (const char *d = std::getenv("PS2_TEX_DUMP"); d && *d) {
            dump_dir = d;
            std::error_code ec; std::filesystem::create_directories(dump_dir, ec);
            std::fprintf(stderr, "[icons] dumping small texture uploads to %s (game-derived: keep them local)\n", d);
        }
        if (const char *p = std::getenv("PS2_ICON_PACK"); p && *p) {
            std::string err;
            if (!load_pack(p, pack, err)) std::fprintf(stderr, "[icons] %s; icons unchanged\n", err.c_str());
            else {
                if (!err.empty()) std::fprintf(stderr, "[icons] %s\n", err.c_str());
                std::fprintf(stderr, "[icons] pack %s: %zu textures to patch\n", p, pack.patches.size());
            }
        }
        on = !dump_dir.empty() || !pack.patches.empty();   // an empty pack costs nothing
    }
};
Hook &hook() { static Hook h; return h; }
}  // namespace

extern "C" bool lifeline_gs_upload_enabled() { return hook().on; }
extern "C" bool lifeline_gs_upload_wanted(std::uint32_t psm, std::uint32_t w, std::uint32_t h) { return wanted(psm, w, h); }

extern "C" void lifeline_gs_upload(std::uint32_t psm, std::uint32_t w, std::uint32_t h, std::uint8_t *data, std::size_t bytes) {
    Hook &k = hook();
    const std::uint64_t id = upload_hash(psm, w, h, data, bytes);
    if (!k.dump_dir.empty() && k.seen.insert(id).second && k.seen.size() <= 20000) {
        dump(k.dump_dir, id, psm, w, h, data, bytes);
        std::ofstream(k.dump_dir + "/uploads.txt", std::ios::app) << hex(id) << " " << w << "x" << h << " " << psm_name(psm) << "\n";
    }
    const auto it = k.pack.patches.find(id);
    if (it == k.pack.patches.end()) return;
    for (const Patch &p : it->second)
        if (!apply(p, psm, w, h, data, bytes)) std::fprintf(stderr, "[icons] %s does not fit %s (%ux%u %s)\n", p.file.c_str(), hex(id).c_str(), w, h, psm_name(psm));
    if (++k.patched <= 20) std::fprintf(stderr, "[icons] patched %s\n", hex(id).c_str());
}
