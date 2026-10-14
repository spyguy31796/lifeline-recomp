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
   - clones `snuri00/ps2-web-recomp` at the pinned, tested commit and applies `0001` + `0002` + `0003`
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
on first start (no root; falls back to `pip install --user`). **The first run needs network** so pip can download pygame-ce (classic pygame has no wheel for SteamOS's Python 3.14);
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
| 4 | Save-anywhere slots | `save_slots` | `PS2_SAVE_SLOTS=1` | works (rebuild once) |
| 5 | Always-on listening | `always_on` | `PS2_VOICE_ALWAYS_ON=1` | coming soon |
| 6 | Large speech model | `large_model` | `PS2_VOICE_VOSK_MODEL=.../vosk-model-en-us-0.22` (if downloaded) | coming soon |
| 7 | Native widescreen | `widescreen` | `PS2_WIDESCREEN=1` | coming soon |
| 8 | Faster loads / skip FMV / 60fps | `faster_loads` | `PS2_FAST_LOADS=1` | coming soon |
| 9 | Faster VU interpreter | `vu_fast` | `PS2_VU_FAST=1` | **works** (off by default; see below) |
| 10 | Button icons (PS2 / Xbox / Steam Deck) | `button_icons` | `PS2_ICON_PACK=<dir>` | works for the OPTION menu (rebuild once); see `icons/README.md` |

"Coming soon" items are greyed out in the launcher; their variables are reserved and ignored by the current build.

**Faster VU interpreter (`[qol] vu_fast`, default off).** From `0006-vu-fast-interpreter-and-check.patch`.
On the Steam Machine the VU1 thread is the bottleneck in 3D scenes. This option makes the runner use a faster VU1
microcode interpreter. It caches each instruction's decoded upper *and* lower op (the original caches only the upper),
dispatches lower ops with computed goto, and keeps the existing skip of MAC/status updates when the uploaded code
never reads them. Any op without a fast handler goes through the original code, so results are identical. When the
option is off (or `PS2_VU_FAST=0` is exported), the original interpreter runs. Takes effect at the next launch; no rebuild.
- **Correctness harness:** `PS2_VU_CHECK=1` runs every fast-path VU1 call twice from the same snapshot: once on the fast
  path (the faster interpreter, or a build-time translated program), once on the original interpreter. It compares
  registers, flags, VU1 memory and the GS packets kicked (captured, not sent), logs the first mismatch per program key
  as `[vu-check] MISMATCH ...`, then keeps the original's result. A summary line is printed at exit.
  `steam-machine/vu-check.sh STATE:END_FRAME ...` runs it headless on states made on this machine (refuses while
  the game is open; logs in `logs/vu-check-*.log`).
- **Self-test:** `PS2_VU_SELFTEST=<n> ps2run` runs n random VU1 programs (no game data) through both interpreters and
  exits 0 only if all match. `build.sh` runs it after the build (result in `build-progress.log`; a failure only warns,
  keep the toggle off). Standalone: `steam-machine/tests/test_vu_fast_selftest.sh <ps2run>`.
- Launcher/run.sh test: `steam-machine/launcher/tests/test_vu_fast.py`.

**First start (Desktop Mode, Konsole):**
```sh
~/lifeline-kit/steam-machine/launcher/launcher.sh
```
After an install it is also copied to `~/lifeline-recomp/launcher/launcher.sh`.

**Rollout note (install fix):** launchers installed before this fix fail at the end of *Install / update* when started
from `~/lifeline-recomp/launcher` (the Steam shortcut). Update once by running the kit's
`~/lifeline-kit/steam-machine/launcher/launcher.sh` and choosing *Install / update*, or by copying the new
`lifeline_launcher.py` into `~/lifeline-recomp/launcher/`. Each install writes `~/lifeline-recomp/logs/install-*.log`.

**Add to Steam:** Desktop Mode → Steam → *Games → Add a Non-Steam Game* → *Browse* → `~/lifeline-recomp/launcher/launcher.sh`
(or the kit copy) → Add, rename it "Lifeline". In Game Mode it opens fullscreen; PLAY starts `run.sh` with your settings,
waits for it, and returns to the launcher menu when the game exits (the quit hotkey exits 0; any other exit code is shown).

### Controller bindings
Launcher → **Controller bindings** remaps every PS2 pad input: Circle (push-to-talk), Cross, Square, Triangle, the
D-pad, L1/L2/L3, R1/R2/R3, START, SELECT and both sticks.
- **A** rebinds the highlighted input: release everything, then press and release the new button, trigger, stick
  direction, hat or key. **Y** adds a second input (e.g. B *and* a back paddle for push-to-talk), **X** clears it,
  **B** goes back and saves. The last row resets everything to the default layout.
- **Cancel:** hold the pressed input for 1.5 s, or press nothing for 6 s. Capture only starts once every button is
  released, so the A you used to open it is never bound by accident.
- Sticks take a whole axis: push right (X) or down (Y) to bind normally, the other way to bind it inverted.
- Saved in `config.ini` under `[bindings]` (no section = the built-in layout). `run.sh` passes it to the game as
  `PS2_INPUT_MAP`; an exported `PS2_INPUT_MAP` wins, and an empty one forces the built-in layout. Headless:
  `launcher.sh --set "bindings.circle=b, paddle1"` (validated with the same rules as the game; a bad source is
  rejected), `launcher.sh --reset-bindings`.
- Editing `config.ini` by hand: inline comments need a space before `#` or `;` (`circle = b, paddle1   # talk`);
  `run.sh` and the launcher both strip them. Separate several inputs with commas. The keys `,` `;` `=` and `#` can't
  be bound (they are separators); the capture screen ignores them.
- Raw joystick indices (`joy:bN`, `joy:aN`, `joy:hN`) must be 0-255; inverted sticks rest at centre like normal ones.
- Source names: `a b x y back guide start leftstick rightstick leftshoulder rightshoulder dpup dpdown dpleft dpright
  misc1 paddle1-4 touchpad`, axes `leftx lefty rightx righty lefttrigger righttrigger` (`+`/`-` prefix = direction for
  buttons, `~` suffix = inverted for sticks), raw `joy:bN`, `joy:aN+`, `joy:hN.up`, and keyboard `key:<SDL key name>`
  (the built-in keyboard keys keep working).
- In Game Mode, Steam Input sits in front of the game: back grips/paddles only reach the game if the Steam controller
  layout passes them through (or maps them to a button you then bind here).
- The game side is `input/` (our code) plus `0003-input-remap-hook.patch`, a weak hook in the runner's input poll;
  `build.sh` applies it (also to existing checkouts) and links `input/*.cpp`. Rebuild once (Install / update) to get it.

### In-game hotkeys
| Action | Keyboard | Controller |
|---|---|---|
| Toggle fullscreen | F11, Alt+Enter | hold Select (Back/View), press R3 (right stick click) |
| Quit to the launcher | hold Ctrl+Q 0.5 s, or hold Esc 1 s | hold Select + Start 1.5 s |
| Save state to the current slot¹ | F5 | hold Select, press R1 (0.5 s) |
| Load the current slot¹ | hold F8 0.5 s | hold Select + L1 1 s |
| Next save slot (1-4)¹ | F6 | hold Select, press D-pad right |

¹ Only with QoL item 4 **Save-anywhere slots** on (`save_slots = 1`, `PS2_SAVE_SLOTS=1`).

#### Save-state slots
- Four slots, saved as `saves/slot1.state` … `slot4.state` next to `run.sh` (`PS2_SAVE_DIR` overrides). The
  selected slot starts at 1 each launch; F6 / Select+Right steps 1→2→3→4→1. The log shows `[slots] ...`.
- The save or load happens at the next frame boundary on the emulation thread (where `--save-state` saves).
  A save is written to `slotN.state.tmp` and renamed over the slot only when complete.
- Before a load, the running game is kept in `saves/before-load.state`. Load it with
  `run.sh --load-state saves/before-load.state` (or copy it over a slot) if you loaded by mistake. If a load fails
  partway, the runner restores that file at once.
- Voice-safe: save and load are refused (`[slots] not now: ...`) while Circle (push-to-talk) is held, while a
  command is being recognized or a new voice context is loading, and for 1.5 s after a result is handed to the game.
  The active voice context is stored in `slotN.voice` and restored on load, along with its vocabulary. A state
  captured mid-listen has the game's recognizer (0x2DBE38) and the game's voice object's own listening flag (this+0x10) reset to idle, so the next Circle press posts cmd 1 (start) then cmd 2 (stop) and listens fresh — not a lone stop. No default
  chord uses Circle. If `slotN.voice` can't be written after a save, the old one is removed so it is never paired
  with the new state (that slot then loads with an unknown context until the game sets the next one).
  The voice-object reset is armed only by a mid-listen load and expires after a few frames, on the next start/stop
  command or the next load, and never clears while our recognizer is listening (`voice/listen_reset.hpp`, unit test in
  `voice/tests/`). Tests: `steam-machine/tests/save-slots-smoke.sh` and `save-slots-midlisten-smoke.sh` (a slot captured mid-listen,
  then one Circle press must post start then stop and be recognized); both need Xvfb + xdotool.
- No on-screen confirmation yet (it is in the log, and the WebGPU presenter has no overlay).
- Memory-card saves are untouched: a slot is a snapshot of the machine, and the card file is not rolled back.
- Code: `input/save_slots.{hpp,cpp}` (decisions), `lifeline_hotkeys()` in `input/input_map_sdl.cpp`, the voice hooks at
  the end of `voice/voice_overrides.cpp`, and `0007-save-state-slots.patch` (`ps2::request_state()` in
  `runtime/src/system.cpp`). There are no runner `poll()` changes. Test: `input/tests/test_save_slots.cpp`.

- Quit is a clean shutdown: the emulator halts, a memory card written in the last frames is saved
  (`[mc] card saved on exit`), queued sound plays out and the audio device is closed, then the runner exits 0, so
  `run.sh` and the launcher return to the launcher menu. Nothing is killed.
- While a quit hold is under way the window title shows `Hold to quit... NN%` (and, with the SDL presenter, a bar along
  the bottom edge); letting go of any button cancels it. The default WebGPU presenter draws no overlay, and in Game
  Mode the title is not visible, so the hold itself is the guard.
- **Chord buttons and the game:**
  - The **first** button of a chord reaches the game as usual until the chord is complete, and keeps reaching it
    after that: a button that was already held is never cut off (a held push-to-talk keeps talking).
  - Buttons pressed **after** the first one are kept from the game while the chord is held (including built-in
    keyboard keys, e.g. Enter = START during Alt+Enter). Pressed in the same frame, none of them reaches the game.
  - There is no input delay, so a partial chord is not held back: **press Select first**, then the other button.
    All controller defaults start with Select, which does nothing harmful during normal play; just say Select.
  - Raw and named bindings for the same button match: with `select = joy:b6`, `start = joy:b7` the default
    `back&start` chord still hides Start, using the pad's SDL mapping (the raw index SDL reports for the named
    button). With no controller mapping (a plain joystick) they can't be matched; bind the chord with the same
    raw inputs instead (`hk_quit = joy:b6&joy:b7@1500`).
  - The launcher warns when a hotkey chord uses a push-to-talk (Circle) input: pressed first it talks, pressed
    later it is held back while the chord is down.
- Rebind them in Launcher → Controller bindings → **Hotkey: fullscreen** / **Hotkey: quit (hold)** (and the save-slot hotkeys): hold every
  button (or key) of the new chord together, then release; the first release binds them all (up to 4). A captured
  quit chord gets a 1.5 s hold. Holding a chord 4 s cancels. **Y** adds another chord, **X** disables the hotkey.
- Stored in `config.ini [bindings]` as `hk_fullscreen` / `hk_quit` and passed in `PS2_INPUT_MAP` like the other
  bindings (env > config). Format: chords separated by `,`, inputs in a chord joined by `&`, optional `@<ms>` hold
  (0-10000): `hk_quit = back&start@1500, key:Escape@1000`. `key:Ctrl`, `key:Alt`, `key:Shift`, `key:GUI` mean either
  side. `none` disables; a hotkey left out keeps its default. The keys `&` and `@` can't be bound. An empty item
  (`a, , b` or a trailing `,`) is reported (`--set` rejects it; the game logs it and keeps the other chords).
- Game side: `input/hotkeys.cpp` (chord/hold state) and `lifeline_hotkeys()` in `input/input_map_sdl.cpp`, hooked by
  `0005-hotkeys-and-clean-quit.patch` (weak hook in the runner's poll, forced memory-card save at halt, audio drain);
  `build.sh` applies it. Rebuild once (Install / update) to get it.
- Tests: `input/tests/test_hotkeys.cpp` (parser, chord/hold timing), launcher `tests/test_bindings.py` (chord
  capture) and `tests/test_play.py` (menu after the game exits), and on a built install
  `xvfb-run -a steam-machine/tests/hotkey-quit-smoke.sh` (Esc tap doesn't quit, F11, Esc hold quits with exit 0).

**Headless checks:** `launcher.sh --print-config`, `launcher.sh --dry-run`, `launcher.sh --set qol.resolution_scale=2`,
and `LIFELINE_PRINT_ENV=1 ~/lifeline-recomp/run.sh` prints the environment run.sh would pass and exits.

### Performance diagnostics and audio buffer
- `run.sh --debug` (or `PS2_PERF_LOG=1`) writes a line per second to `logs/run-<time>.log`:
  `[perf] 58.9 fps  CPU 140%  GPU 35%  audio 96 ms (target 120)  starved frames 4 (+1)  dropouts 2 (+1)`.
  **Window mode only** (normal play, `--window`/`--fullscreen`); headless runs (`--frames` without a window) print nothing.
  - `audio`: sound queued right now. `starved frames`: frames where less than one device buffer (~21 ms at 1024)
    was queued, which is when SDL fills with silence (the crackle). It also counts a queue that never fills at low fps.
    `dropouts`: separate starvation episodes.
  - If fps stays below 60 the queue can't stay full and audio will crackle whatever the buffer size: the game is
    paced by the audio clock, so the log tells you whether a slowdown is sustained or a short spike.
- `PS2_AUDIO_BUFFER_MS` (default **120**, was a fixed 80; integer 20-400, clamped; raised to at least 2x the device
  buffer with a warning, e.g. 43 ms at 1024): how much sound is kept queued.
  Bigger rides out short stalls (e.g. a voice command being decoded) at the cost of that much extra latency.
  Incoming sound is dropped above target + two device buffers, so latency can't build past that.
- `PS2_AUDIO_SAMPLES` (default 1024; power of two 256-8192): SDL device buffer size.
- Values that aren't plain positive integers (`abc`, empty, `-5`, `1e3`, `12ms`) fall back to the default with an
  `[audio]` warning on stderr; the startup `[audio]` line shows the values in effect.
- From `0004-audio-buffer-and-perf-log.patch` (`host/audio_pacing.hpp` + `host/window.cpp`; unit test in
  `tests/test_audio_pacing.cpp`); `build.sh` applies it (also to existing checkouts).

### CPU-tuned build (optional, rebuild)
- Launcher item **CPU-tuned build (rebuild)**, `config.ini`:
  ```ini
  [build]
  cpu_tuned = 1      # default 0
  ```
  or `lifeline_launcher.py --set build.cpu_tuned=1`.
- It changes the compiled binary, so it only takes effect on the next **Install / update**. The launcher shows
  `ON (rebuild)` / `off (rebuild)` and a hint until the build matches the setting.
- When on, `build.sh` (env `CPU_TUNED=1`) compiles with `-march=native -flto=thin` and links with `-fuse-ld=lld`
  (ThinLTO, tuned for this machine's CPU; `CPU_MARCH=znver4` etc. overrides `native`). PGO is not used.
  If the tuned build fails (for example an LTO/linker error), it rebuilds generic and records `generic-fallback`;
  without `ld.lld` it uses `-march` only. The flavor actually built is in `~/lifeline-recomp/build-flavor`, and the
  flags plus flavor are written to `build.log`, `build-progress.log` and the launcher's `logs/install-*.log`.
- **Warning: `-march=native` binaries are tied to the CPU they were built on.** Copied to another machine (or a
  different Steam Machine / handheld model), they may crash at start with "Illegal instruction". Don't share or
  copy a tuned `ps2run`; rebuild on each machine. `build-flavor` records the CPU model (`cpu=...`), and when a
  tuned build finds a different CPU the launcher prompts at start and shows `ON (rebuild: new CPU)` until
  Install / update rebuilds it. Generic builds run anywhere and never prompt.
- `CPU_MARCH` (env for `build.sh`) replaces `native` with a fixed target, e.g. `CPU_MARCH=znver2`. Pick one that
  every machine you run on supports (too new = illegal instruction; `x86-64-v3` is a safe AVX2 baseline); the
  launcher doesn't set it, and the CPU check above still applies to the machine that built it.
- Every configure (before `port.sh` and the final one) passes the same `-DCMAKE_CXX_FLAGS` /
  `-DCMAKE_EXE_LINKER_FLAGS`, so switching flavor recompiles once and stale cached flags (e.g. `-fuse-ld=lld` after
  lld was removed) are replaced before the first compile. If the tuned first compile fails anyway, the build falls
  back to generic right there. The first install into a new build dir compiles twice when tuned (`port.sh`
  configures it without our flags).
- Expected gain is modest; see the PR for measured numbers. Hot spots on the Steam Machine are the interpreted VU1
  microcode and the EE thread waiting on it, which a compiler flag can only speed up a little.
- Logic in `steam-machine/cpu_flags.sh`; tests: `bash steam-machine/tests/test_cpu_flags.sh`,
  `python3 steam-machine/launcher/tests/test_cpu_tuned.py`.

## Known limits
- Accuracy depends on the small Vosk model and your mic. Natural-sentence matching was tuned with synthetic voices plus one player's sessions.
- A misheard word can still map to a different command that's valid in the current room.
- The loose matching only applies when Vosk is fairly confident (confidence ≥ 6000); otherwise you need closer wording.
- Words are not checked for meaning together, so an odd verb + object pair can be accepted if both exist in the room.
- Only the NTSC-U disc (SLUS_208.48) is supported. Linux only for now.
- If no mic is selected, SDL records from a silent null device and nothing is heard; reconnect the headset and pick it as input.
- VU microcode is interpreted, so performance depends on the CPU.

### Updating an existing install (build.sh)
- Patches are applied by `steam-machine/patches.sh`. Applied ones are recorded in
  `ps2-web-recomp/.git/lifeline-patches` as `name sha256` lines (written atomically right after each apply), with a
  copy of each applied patch in `.git/lifeline-patches.d/`. Re-running applies nothing.
- A patch whose sha256 changed is taken back out (with every later patch) using the stored copies and applied
  again.
- No marker (older kits, or an interrupted clone), a marker from the previous kit (names only), an unreadable
  one, or a patch that fails to apply: the tree is checked instead. The newest patch that reverse-applies is
  applied, and so is everything before it, down to 0001; the rest are applied.
- **Recovery:** if patching still fails, delete `ps2-web-recomp/.git/lifeline-patches` and run Install / update
  again; if that fails too, `git -C ~/lifeline-recomp/ps2-web-recomp reset --hard` first (a fresh clone also works).
- An existing build dir is re-configured before the first compile, so new `voice/` or `input/` files are linked.
- The previous `ps2run` is copied to `ps2run.prev` and put back if any compile or link fails ("build failed: the
  previous ps2run was kept"). A killed build (SIGKILL, power loss) can't run that restore; the next run finds
  `ps2run.prev` and puts it back first ("restored ps2run from an interrupted build"), or `mv` it back by hand.
  The restore copies to `ps2run.tmp` and renames it over `ps2run`, and skips (with a warning) a `.prev` that is
  empty or not executable. A marker that claims a patch the tree lacks makes the apply loop start over at the
  first missing patch instead of failing.
- Tests: `steam-machine/tests/patch-marker-test.sh` (fast, synthetic checkout: unpatched, partial, older kit,
  name-only / corrupt / CRLF marker, changed patch, apply-failure fallback,
  stale marker restart), `bash steam-machine/tests/test_ps2run_restore.sh` (ps2run.prev restore) and
  `steam-machine/tests/build-upgrade-test.sh <built-workdir> <iso> <scratch-dir>` (previous release -> new
  build.sh twice, then a source that can't link).

## Repo layout
| Path | What |
|---|---|
| `0001-usbmic-hle-and-deci2-nohost.patch` | Patch for ps2-web-recomp: USB mic HLE and DECI2 no-host |
| `0002-ee-overrides-and-voice-stage-a-b.patch` | Patch for ps2-web-recomp: EE function overrides and voice module hooks |
| `voice/` | Voice module that replaces the original recognizer (Vosk backend, SDL mic, phrase-table reader, natural-sentence matcher) |
| `voice/tools/` | `fat.py` / `arcx.py` extract the phrase tables from your ISO; `build_aliases.py` builds the local alias table |
| `steam-machine/` | `build.sh` (+ `patches.sh`), `run.sh`, `make-skip-state.sh`, `vu-check.sh` and kit notes |
| `0003-input-remap-hook.patch` | Patch for ps2-web-recomp: weak hook that lets `input/` remap the controller |
| `0004-audio-buffer-and-perf-log.patch` | Patch for ps2-web-recomp: configurable audio pacing buffer, underrun counter, `[perf]` log line |
| `0005-hotkeys-and-clean-quit.patch` | Patch for ps2-web-recomp: hotkey hook (fullscreen, hold-to-quit), card save and audio drain on exit |
| `0006-vu-fast-interpreter-and-check.patch` | Patch for ps2-web-recomp: faster VU1 interpreter (`PS2_VU_FAST`), `PS2_VU_CHECK` shadow harness, `PS2_VU_SELFTEST` (only touches `runtime/src/vu_micro.cpp`) |
| `0007-save-state-slots.patch` | Patch for ps2-web-recomp: `request_state()`, a save/load at the next frame boundary for the save-slot hotkeys |
| `0008-texture-upload-hook.patch` | Patch for ps2-web-recomp: optional hook on small host→GS texture uploads (button icon packs) |
| `icons/` | Button icon packs (our art), manifest/blit code, texture-dump tool, tests |
| `input/` | Controller remap layer and hotkeys (`PS2_INPUT_MAP` parser, chord/hold state, SDL apply) and their unit tests |
| `steam-machine/launcher/` | Controller launcher: install/update, QoL toggles (`config.ini`), launch options |
| `steam-machine/cpu_flags.sh` | CPU-tuned build flags (`[build] cpu_tuned`) with generic fallback; test in `steam-machine/tests/` |

## License
Our code is MIT (see `LICENSE`). ps2-web-recomp is MIT and is not vendored: `build.sh` clones it and applies our patches.
Vosk and the Vosk model are Apache-2.0 and are downloaded at build time. *Lifeline* is © Konami; this project is
unofficial and not affiliated with Konami.
