# Lifeline native recomp — Steam Machine kit (build from your own disc)

**This kit contains only our code** (scripts + `../0001`, `../0002`, `../voice/`). Paths below like `~/lifeline-kit/ourcode` mean wherever you cloned this repo.
The `ps2run` it builds contains code translated from the game, so it is
**game-derived: build it on your own machine from your own disc, never copy or share it.**
Status: V1, built and played on a Steam Machine (SteamOS). See the top-level README.md for the install guide.

## Target (public info)
- Steam Machine (2026): semi-custom AMD Zen 4, 6C/12T (2× Zen 4 + 4× Zen 4c), up to 4.8 GHz, 30 W;
  semi-custom RDNA 3 (Navi 33-derived), 28 CUs, 2.45 GHz, 8 GB GDDR6; 16 GB DDR5; SteamOS 3 (Arch-based, KDE desktop mode).
  Sources: Digital Foundry review <https://www.digitalfoundry.net/reviews/steam-machine-beautiful-hardware-console-performance-at-a-price>,
  9to5Linux <https://9to5linux.com/steam-machines-is-up-for-reservation-from-1049-with-arch-linux-based-steamos-3>.
- SteamOS has a read-only root. Since SteamOS 3.5 it ships **Distrobox + Podman** (rootless). Containers live in
  `$HOME` and survive OS updates. Sources: Igalia <https://blogs.igalia.com/berto/2024/06/05/more-ways-to-install-software-in-steamos-distrobox-and-nix/>,
  Distrobox compatibility <https://distrobox.it/compatibility/>, KDE dev docs <https://develop.kde.org/docs/getting-started/building/containers-distrobox/>.
- Unverified: whether the Steam Machine's SteamOS build still ships distrobox at the same version. Check with `distrobox --version` in Desktop Mode.

## Why Distrobox (vs alternatives)
| Option | Verdict |
|---|---|
| **Distrobox/Podman (Arch image)** | **Chosen.** Preinstalled, rootless, all in `$HOME`, survives updates, and gives full `pacman` for cmake/ninja/clang/sdl2. The container sees `$HOME`, Wayland/X11, PipeWire/Pulse and `/dev` (so mic and controller work). |
| `steamos-readonly disable` + pacman | Rejected. Changes the system and is wiped by OS updates. |
| Flatpak SDK (`org.freedesktop.Sdk`) | Possible, but you'd have to write a manifest and set up sandbox permissions for the mic, the ISO path and input. More work, no benefit here. |
| Nix (single-user) | Works per Igalia, but it's an extra installer to bootstrap. Keep as a fallback. |

Note: `sudo pacman` in build.sh runs **inside the rootless container only**. The host stays untouched.
Distrobox's SteamOS guide suggests `export PIPEWIRE_RUNTIME_DIR=/dev/null` in `~/.distroboxrc` if container audio misbehaves. Try that only if mic capture fails.

## Build (Desktop Mode, Konsole, user `deck`)
```sh
# copy ourcode/ (with steam-machine/) to the device, e.g. ~/lifeline-kit/ourcode
~/lifeline-kit/ourcode/steam-machine/build.sh            # ISO default: /home/deck/Downloads/Life Line (USA).iso
# override: build.sh /path/to/disc.iso [workdir]   or LIFELINE_ISO=... LIFELINE_WORK=...
```
What it does: creates distrobox `lifeline-build` (archlinux) → installs git cmake ninja clang python python-pip sdl2 curl unzip p7zip
→ clones `snuri00/ps2-web-recomp` @ `1b4808793a12c45125262fd2d5f50a9ec9f7c020` → applies 0001 + 0002
→ `scripts/port.sh lifeline <iso> --native-only --no-explore` (the explore pass found no new entries here; pass `PORT_ARGS=` to explore)
→ re-translates with `--overrides voice/overrides.txt` and relinks with `PS2_EXTRA_SOURCES` = every `voice/*.cpp` (libvosk is loaded with dlopen at run time, so the build doesn't need it)
→ fetches **on the device** `libvosk.so` from the PyPI `vosk==0.3.45` wheel (`pip download`) and `vosk-model-small-en-us-0.15` (Apache-2.0) from alphacephei.com → extracts the voice context tables from your ISO with `voice/tools/fat.py` + `arcx.py` into `~/lifeline-recomp/voice-assets`
→ writes `~/lifeline-recomp/{lifeline.env,run.sh,saves/}`. Everything goes under `~/lifeline-recomp`.

## Launch
1. Test from Konsole: `~/lifeline-recomp/run.sh` (window, memcard `~/lifeline-recomp/saves/lifeline.ps2`).
   Debug: `~/lifeline-recomp/run.sh --debug` sets `PS2_VOICE_DEBUG=1` and `PS2_VOICE_LOG=~/lifeline-recomp/logs/voice.log`, and saves stderr to `logs/run-<ts>.log`.
2. Add to Steam: Steam (Desktop Mode) → *Games → Add a Non-Steam Game* → *Browse* → `/home/deck/lifeline-recomp/run.sh` → Add.
   For fullscreen, set launch options in Properties to `--fullscreen`, or `--debug --fullscreen` for debug.
3. Return to Game Mode and launch "run.sh". Rename it "Lifeline" in Properties.

## Controls: "hold circle to talk"
ps2run maps SDL GameController **B (east face button) → PS2 Circle** (`host/window.cpp`). On a Steam/Xbox-layout pad that's the B button by default.
Hold it while speaking (the game sends cmd 1/3 while held; the result is read on release). Square advances text, START opens pause.
To move talk to a back grip or trigger: Steam → game → Controller layout → bind the button to "B". Unverified on the device.

## Mic / voice status
- `voice/` now has a Vosk backend (`vosk_recognizer.cpp`, dlopen) plus an SDL audio source. If libvosk or the model is missing, it falls back to the null recognizer.
  run.sh sets `PS2_VOICE_VOSK_MODEL`, `PS2_VOICE_VOSK_LIB` and `PS2_VOICE_ASSETS` from `lifeline.env`. It never sets `PS2_VOICE_WAV_*` or `PS2_VOICE_INJECT`.
- SDL capture uses `SDL_AUDIODRIVER=pipewire,pulseaudio`.

## Performance caveat
On the dev box (no GPU) the runner managed about 10–13 fps, and VU microprograms are interpreted. Device speed is unmeasured.
