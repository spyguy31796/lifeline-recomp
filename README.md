# Lifeline Recomp

A native Linux (SteamOS first) build of **Lifeline** (Konami, PS2, 2004), the voice-controlled survival horror game,
made by static recompilation with [ps2-web-recomp](https://github.com/snuri00/ps2-web-recomp). The game's old USB-headset
recognizer is replaced with an offline [Vosk](https://alphacephei.com/vosk/) recognizer that listens to any mic, plus
quality-of-life fixes.

**V1 features**
- Runs natively (Vulkan through wgpu, SDL input and audio). No emulator.
- Offline voice recognition with any mic: hold **Circle** (the **B** / east button on a Steam or Xbox-style pad) while you speak.
- Natural sentences: say a full sentence such as "walk over to the X" or "can you go to the X please" instead of only a bare command and object.
  Filler words are ignored, common verb synonyms work (walk/go/move/head, look/check/examine, take/pick/grab...),
  and objects still match despite plural/singular or small mishearings.
- Spoken numbers work (the small model hears digits as words); anything the game can't use gets the game's normal "BAD!" feedback instead of silence.
- Optional save state that skips the tutorial, made locally from your own disc.
- Voice log at `logs/voice.log` that shows what was heard and why it was accepted or rejected.

## Legal: bring your own disc
**This repository contains no game data:** no ISO, no executable, no extracted files, no voice/phrase tables, no save
states and no game text. Everything game-derived is created on **your** machine from **your own legally dumped copy**
of the NTSC-U disc (**SLUS_208.48**, "Life Line (USA)"). The built `ps2run` contains code translated from the game,
so it is game-derived too: keep it on your machine and never share it, or the voice assets, saves or aliases it creates.

## Requirements
- Linux x86_64. Tested on a Steam Machine running SteamOS 3. Other distros should work with `KIT_NO_CONTAINER=1` and the packages listed in `steam-machine/build.sh`.
- `distrobox` with Podman (preinstalled on SteamOS 3.5+). The build runs inside a rootless container named `lifeline-build`, so the read-only system is never changed.
- A Vulkan GPU, a microphone (USB or Bluetooth headset) and a controller.
- About 30 minutes for the first build (a full build took about 5.5 minutes on the Steam Machine, plus downloads), and a few GB free in `$HOME`.
- Internet during the build (upstream source, container packages, Vosk).

## Install
All commands run in Desktop Mode → Konsole as your normal user. Nothing needs root on the host.

1. **Dump your disc** to an ISO with your own drive, e.g. `~/Downloads/Life Line (USA).iso`.
2. **Get this repo:**
   ```sh
   git clone https://github.com/spyguy31796/lifeline-recomp.git ~/lifeline-kit
   ```
3. **Build** (pass your ISO path; the output goes to `~/lifeline-recomp`):
   ```sh
   ~/lifeline-kit/steam-machine/build.sh "$HOME/Downloads/Life Line (USA).iso"
   ```
   Watch progress with `tail -f ~/lifeline-recomp/build-progress.log` (full log: `build.log`).
   The script:
   - creates the `lifeline-build` distrobox and installs the compilers and libraries inside it
   - clones `snuri00/ps2-web-recomp` at the pinned, tested commit and applies `0001` + `0002`
   - recompiles your disc's executable and links in the voice module from `voice/`
   - downloads Vosk (see below)
   - extracts the voice phrase tables from your ISO into `~/lifeline-recomp/voice-assets/`
   - writes `~/lifeline-recomp/run.sh` and `lifeline.env`
4. **Vosk speech model.** `build.sh` downloads these automatically into `~/lifeline-recomp/vosk/`; they are never bundled here:
   - `libvosk.so` from the PyPI wheel `vosk==0.3.45` (Apache-2.0)
   - the model [`vosk-model-small-en-us-0.15`](https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip) (Apache-2.0)

   To do it by hand (or with `SKIP_VOSK=1`): unzip the model into `~/lifeline-recomp/vosk/`, and extract `vosk/libvosk.so` from the wheel into `~/lifeline-recomp/vosk/vosk/libvosk.so`.
5. **Build the spoken-form aliases** (recommended; it fixes game words the small model doesn't know):
   ```sh
   distrobox enter lifeline-build -- python3 ~/lifeline-kit/voice/tools/build_aliases.py \
     --assets ~/lifeline-recomp/voice-assets \
     --model  ~/lifeline-recomp/vosk/vosk-model-small-en-us-0.15
   ```
   This writes `voice-assets/aliases.tsv` (install `espeak-ng` in the container for better sound-alike matches). Words it can't solve
   are listed in `aliases.unresolved.txt`; put your own `word<TAB>spoken form` fixes in `voice-assets/aliases.local.tsv`, which takes priority.
6. **(Optional) Make the skip-tutorial save:**
   ```sh
   cp ~/lifeline-kit/steam-machine/make-skip-state.sh ~/lifeline-recomp/
   ~/lifeline-recomp/make-skip-state.sh
   ```
   It replays the tutorial on your own disc with no mic and saves `~/lifeline-recomp/saves/room001.state` (the first playable room).
   It needs `~/lifeline-recomp/saves/tutorial-queue.txt`, which you write yourself: the answers the tutorial asks you to say, one per
   line in order (play the tutorial once and note them). That's game text, so it isn't included here; keep it local.

## Play
1. Connect your headset and choose it as the **input** device in the system sound settings before launching.
2. Launch:
   ```sh
   ~/lifeline-recomp/run.sh                   # new game (windowed)
   ~/lifeline-recomp/run.sh --skip-tutorial   # start in the first room from saves/room001.state
   ~/lifeline-recomp/run.sh --fullscreen
   ~/lifeline-recomp/run.sh --debug           # voice log on + stderr to logs/run-<time>.log
   ```
   Options can be combined. Any extra arguments are passed through to `ps2run`.
3. **Hold Circle / B while you speak** and release when you're done. Square advances text, START pauses.
4. Talk normally, in full sentences or short commands; the words the game accepts change with each room.
5. With debug on (the launcher's default, or `run.sh --debug`), every utterance is logged to `~/lifeline-recomp/logs/voice.log`: what Vosk heard, its confidence, and whether it matched
   exactly, loosely, or why it was rejected. Check it when a command doesn't work.

### Add to Steam (Game Mode)
Desktop Mode → Steam → *Games → Add a Non-Steam Game to My Library* → *Browse* → pick `~/lifeline-recomp/run.sh` → Add.
In the shortcut's *Properties*, rename it "Lifeline" and add launch options such as `--skip-tutorial --fullscreen`.
To move push-to-talk to another button, remap that button to **B** in the Steam controller layout.

## Launcher (controller-friendly installer + QoL toggles)
`steam-machine/launcher/` is a small Python + pygame app that works with a controller in SteamOS Game Mode.
pygame's wheel bundles SDL2, so `launcher.sh` creates a per-user venv in `~/lifeline-recomp/launcher-venv`
on first start (no root; falls back to `pip install --user`). **The first run needs network** so pip can download pygame;
if both fail it shows an error and the details are in `~/lifeline-recomp/launcher.log`.

**Controls:** D-pad / left stick = move, **A** = select or toggle, **left/right** = change a value, **START** = play, **B** = back/quit.
Keyboard works too (arrows, Enter, Esc).

**What it does**
- **Install / update from ISO:** pick your ISO (cycles through `*.iso` in `~/Downloads` and `~`), then it runs `build.sh`
  (build, voice assets, Vosk lib + small model) and `voice/tools/build_aliases.py`, showing `build-progress.log` live.
  Your `voice-assets/aliases.local.tsv` is never overwritten.
- **Download large speech model:** optional `vosk-model-en-us-0.22` (~1.8 GB zip) into `~/lifeline-recomp/vosk/`. It checks free space first,
  verifies the sha256, and deletes partial downloads on failure. `build.sh` pins and verifies the sha256 of the Vosk wheel and small model the same way.
- **Launch:** PLAY (continue), New game, and toggles for skip tutorial, fullscreen, debug logs, voice off.
  **Debug logs is ON in a freshly created `config.ini`** so `logs/voice.log` keeps being written while voice is tuned.
  `run.sh` on its own now defaults to `PS2_VOICE_DEBUG=0`; `--debug` turns the voice log (and the stderr log) on.
- **QoL toggles**, saved to `~/lifeline-recomp/config.ini` and read by `run.sh` each launch. Precedence: a variable already in your environment > `config.ini` > `lifeline.env`
  (e.g. `PS2_VOICE_OFF=0` beats `voice_off = 1`; a `PS2_VOICE_VOSK_MODEL` you export is never replaced by the large-model toggle):

| # | Toggle | config key | run.sh passes | Status |
|---|---|---|---|---|
| 1 | On-screen voice readout | `voice_readout` | `PS2_VOICE_OVERLAY=1` | coming soon |
| 2 | Voice tuning config | `voice_tuning` | `PS2_VOICE_CONFIG=~/lifeline-recomp/voice.ini` | coming soon |
| 3 | Internal resolution 1x/2x/3x | `resolution_scale` | `PS2_SCALE=<n>` | **works** (AA coming soon) |
| 4 | Save-anywhere slots | `save_slots` | `PS2_SAVE_SLOTS=1` | coming soon |
| 5 | Always-on listening | `always_on` | `PS2_VOICE_ALWAYS_ON=1` | coming soon |
| 6 | Large speech model | `large_model` | `PS2_VOICE_VOSK_MODEL=.../vosk-model-en-us-0.22` (if downloaded) | coming soon |
| 7 | Native widescreen | `widescreen` | `PS2_WIDESCREEN=1` | coming soon |
| 8 | Faster loads / skip FMV / 60fps | `faster_loads` | `PS2_FAST_LOADS=1` | coming soon |

"Coming soon" items are greyed out in the launcher; their variables are reserved and ignored by the current build.

**First start (Desktop Mode, Konsole):**
```sh
~/lifeline-kit/steam-machine/launcher/launcher.sh
```
After an install it is also copied to `~/lifeline-recomp/launcher/launcher.sh`.

**Add to Steam:** Desktop Mode → Steam → *Games → Add a Non-Steam Game* → *Browse* → `~/lifeline-recomp/launcher/launcher.sh`
(or the kit copy) → Add, rename it "Lifeline". In Game Mode it opens fullscreen; PLAY starts `run.sh` with your settings and
returns to the launcher if the game exits with an error.

**Headless checks:** `launcher.sh --print-config`, `launcher.sh --dry-run`, `launcher.sh --set qol.resolution_scale=2`,
and `LIFELINE_PRINT_ENV=1 ~/lifeline-recomp/run.sh` prints the environment run.sh would pass and exits.

## Known limits
- Accuracy depends on the small Vosk model and your mic. Natural-sentence matching was tuned with synthetic voices plus one player's sessions.
- A misheard word can still map to a different command that's valid in the current room.
- The loose matching only applies when Vosk is fairly confident (confidence ≥ 6000); otherwise you need closer wording.
- Words are not checked for meaning together, so an odd verb + object pair can be accepted if both exist in the room.
- Only the NTSC-U disc (SLUS_208.48) is supported. Linux only for now.
- If no mic is selected, SDL records from a silent null device and nothing is heard; reconnect the headset and pick it as input.
- VU microcode is interpreted, so performance depends on the CPU.

## Repo layout
| Path | What |
|---|---|
| `0001-usbmic-hle-and-deci2-nohost.patch` | Patch for ps2-web-recomp: USB mic HLE and DECI2 no-host |
| `0002-ee-overrides-and-voice-stage-a-b.patch` | Patch for ps2-web-recomp: EE function overrides and voice module hooks |
| `voice/` | Voice module that replaces the original recognizer (Vosk backend, SDL mic, phrase-table reader, natural-sentence matcher) |
| `voice/tools/` | `fat.py` / `arcx.py` extract the phrase tables from your ISO; `build_aliases.py` builds the local alias table |
| `steam-machine/` | `build.sh`, `run.sh`, `make-skip-state.sh` and kit notes |
| `steam-machine/launcher/` | Controller launcher: install/update, QoL toggles (`config.ini`), launch options |

## License
Our code is MIT (see `LICENSE`). ps2-web-recomp is MIT and is not vendored: `build.sh` clones it and applies our patches.
Vosk and the Vosk model are Apache-2.0 and are downloaded at build time. *Lifeline* is © Konami; this project is
unofficial and not affiliated with Konami.
