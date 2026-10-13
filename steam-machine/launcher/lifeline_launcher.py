#!/usr/bin/env python3
"""Lifeline Recomp launcher: install/update from your own ISO, QoL toggles, launch.

Controller-first (SDL GameController via pygame): D-pad/left stick = move, A = select/toggle,
B = back, START = play. Keyboard: arrows, Enter, Esc. Works in SteamOS Game Mode as a non-Steam game.

Headless helpers (no window):
  lifeline_launcher.py --print-config        show config.ini as run.sh will see it
  lifeline_launcher.py --dry-run             print the run.sh command that PLAY would execute
  lifeline_launcher.py --set qol.resolution_scale=2 [--set ...]   edit config and exit
Contains only our code; never bundles game data.
"""
import configparser, glob, os, shlex, subprocess, sys, threading, time, urllib.request, zipfile, shutil

HOME = os.path.expanduser("~")
WORK = os.environ.get("LIFELINE_WORK", os.path.join(HOME, "lifeline-recomp"))
CFG = os.path.join(WORK, "config.ini")
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ISO = os.path.join(HOME, "Downloads", "Life Line (USA).iso")
LARGE_MODEL = "vosk-model-en-us-0.22"
SMALL_MODEL = "vosk-model-small-en-us-0.15"

# key, label, kind ('bool' or ('choice', values)), available now?, one-line help
QOL = [
    ("voice_readout",    "1 On-screen voice readout",   "bool", False, "Shows what was heard + match/reject (PS2_VOICE_OVERLAY)"),
    ("voice_tuning",     "2 Voice tuning config",       "bool", False, "Reads voice.ini at launch (PS2_VOICE_CONFIG)"),
    ("resolution_scale", "3 Internal resolution",       ("choice", ["1", "2", "3"]), True, "PS2_SCALE: 1 = native, 2-3 = sharper (AA coming soon)"),
    ("save_slots",       "4 Save-anywhere slots",       "bool", False, "Save-state slots on a hotkey/menu"),
    ("always_on",        "5 Always-on listening",       "bool", False, "Voice activity presses talk for you (PS2_VOICE_ALWAYS_ON)"),
    ("large_model",      "6 Large speech model",        "bool", False, "Uses %s if downloaded (better names, slower)" % LARGE_MODEL),
    ("widescreen",       "7 Native widescreen",         "bool", False, "True 16:9 with correct field of view"),
    ("faster_loads",     "8 Faster loads / skip FMV / 60fps", "bool", False, "Fast-forward loads, skip seen FMVs"),
]
LAUNCH = [("skip_tutorial", "Skip tutorial (needs saves/room001.state)"),
          ("fullscreen", "Fullscreen"), ("debug", "Debug logs"), ("voice_off", "Voice off (PS2_VOICE_OFF)")]
DEFAULTS = {"launch": {"skip_tutorial": "0", "fullscreen": "1", "debug": "0", "voice_off": "0"},
            "qol": {k: ("1" if k == "resolution_scale" else "0") for k, *_ in QOL},
            "paths": {"iso": DEFAULT_ISO, "kit": os.path.dirname(HERE)}}


def load():
    c = configparser.ConfigParser()
    c.read_dict(DEFAULTS)
    c.read(CFG)
    return c


def save(c):
    os.makedirs(WORK, exist_ok=True)
    tmp = CFG + ".tmp"
    with open(tmp, "w") as f:
        f.write("# Lifeline Recomp launcher config; run.sh reads [qol]. 'coming soon' items are reserved.\n")
        c.write(f)
    os.replace(tmp, CFG)


def play_cmd(c, new_game=False):
    a = [os.path.join(WORK, "run.sh")]
    if not new_game and c.getboolean("launch", "skip_tutorial"): a.append("--skip-tutorial")
    if c.getboolean("launch", "debug"): a.append("--debug")
    if c.getboolean("launch", "fullscreen"): a.append("--fullscreen")
    return a


def play_env(c):
    e = dict(os.environ)
    if c.getboolean("launch", "voice_off"): e["PS2_VOICE_OFF"] = "1"
    return e


def kit_dir(c):
    k = c.get("paths", "kit")
    for cand in (k, os.path.join(HOME, "lifeline-kit", "steam-machine"), os.path.join(HOME, "lifeline-kit", "ourcode", "steam-machine")):
        if os.path.isfile(os.path.join(cand, "build.sh")): return cand
    return k


def find_isos(c):
    s = [c.get("paths", "iso")] + sorted(glob.glob(os.path.join(HOME, "Downloads", "*.iso")) + glob.glob(os.path.join(HOME, "*.iso")))
    out = []
    for p in s:
        if p not in out and os.path.isfile(p): out.append(p)
    return out or [c.get("paths", "iso")]


# ---------------- install / update (runs in a thread, reports lines) ----------------
class Job:
    def __init__(self, title, fn):
        self.title, self.lines, self.done, self.ok = title, [], False, None
        threading.Thread(target=self._run, args=(fn,), daemon=True).start()

    def log(self, s):
        self.lines.append(s.rstrip()); self.lines[:] = self.lines[-200:]

    def _run(self, fn):
        try: self.ok = bool(fn(self))
        except Exception as ex: self.log("ERROR: %s" % ex); self.ok = False
        self.done = True


def _stream(job, cmd, progress=None):
    job.log("$ " + " ".join(shlex.quote(x) for x in cmd))
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    seen = len(open(progress, errors="replace").read().splitlines()) if progress and os.path.exists(progress) else 0
    for line in p.stdout:
        if progress and os.path.exists(progress):      # prefer the compact phase log for the screen
            with open(progress, errors="replace") as f: pl = f.read().splitlines()
            for l in pl[seen:]: job.log(l)
            seen = len(pl)
        elif not progress: job.log(line)
    return p.wait() == 0


def install(job, c):
    kit, iso = kit_dir(c), c.get("paths", "iso")
    if not os.path.isfile(iso): job.log("ISO not found: " + iso); return False
    local = os.path.join(WORK, "voice-assets", "aliases.local.tsv")
    keep = open(local, "rb").read() if os.path.exists(local) else None
    prog = os.path.join(WORK, "build-progress.log")
    job.log("Building from your ISO (progress: build-progress.log, full: build.log)")
    if not _stream(job, ["bash", os.path.join(kit, "build.sh"), iso, WORK], progress=prog):
        job.log("build.sh failed; see " + os.path.join(WORK, "build.log")); return False
    job.log("Building spoken-form aliases ...")
    tool = os.path.join(os.path.dirname(kit), "voice", "tools", "build_aliases.py")
    cmd = ["python3", tool, "--assets", os.path.join(WORK, "voice-assets"), "--model", os.path.join(WORK, "vosk", SMALL_MODEL)]
    if shutil.which("distrobox") and not os.path.exists("/run/.containerenv"): cmd = ["distrobox", "enter", "lifeline-build", "--"] + cmd
    ok = _stream(job, cmd)
    if keep is not None and (not os.path.exists(local) or open(local, "rb").read() != keep):
        open(local, "wb").write(keep); job.log("restored aliases.local.tsv")
    inst = os.path.join(WORK, "launcher"); os.makedirs(inst, exist_ok=True)
    for f in ("lifeline_launcher.py", "launcher.sh"):
        shutil.copy2(os.path.join(HERE, f), os.path.join(inst, f))
    shutil.copy2(os.path.join(kit, "run.sh"), os.path.join(WORK, "run.sh"))
    job.log("Done." if ok else "Aliases step failed (game still playable).")
    return True


def download_large(job, c):
    d = os.path.join(WORK, "vosk"); os.makedirs(d, exist_ok=True)
    if os.path.isdir(os.path.join(d, LARGE_MODEL)): job.log("Already downloaded."); return True
    url = "https://alphacephei.com/vosk/models/%s.zip" % LARGE_MODEL
    z = os.path.join(d, LARGE_MODEL + ".zip.part")
    job.log("Downloading " + url)
    with urllib.request.urlopen(url) as r, open(z, "wb") as f:
        tot, got, last = int(r.headers.get("Content-Length") or 0), 0, 0
        while True:
            b = r.read(1 << 20)
            if not b: break
            f.write(b); got += len(b)
            if time.time() - last > 1:
                last = time.time(); job.log("  %d MB%s" % (got >> 20, " / %d MB" % (tot >> 20) if tot else ""))
    job.log("Unpacking ..."); zipfile.ZipFile(z).extractall(d); os.remove(z)
    job.log("Done: " + os.path.join(d, LARGE_MODEL)); return True


# ---------------- UI ----------------
def menu_items(c):
    built = os.path.isfile(os.path.join(WORK, "run.sh")) and os.path.isfile(os.path.join(WORK, "lifeline.env"))
    m = [("play", "PLAY (continue / memory card)", built), ("new", "New game", built)]
    m += [("launch:" + k, lbl, True) for k, lbl in LAUNCH]
    m += [("qol:" + k, lbl, avail) for k, lbl, kind, avail, _ in QOL]
    m += [("iso", "ISO", True), ("install", "Install / update from ISO", True),
          ("large", "Download large speech model (~1.8 GB)", True), ("quit", "Quit", True)]
    return m


def value_of(c, key):
    if key.startswith("launch:"): return "ON" if c.getboolean("launch", key[7:]) else "off"
    if key.startswith("qol:"):
        k = key[4:]; kind = next(q[2] for q in QOL if q[0] == k)
        if kind == "bool": return "ON" if c.get("qol", k) == "1" else "off"
        return c.get("qol", k) + "x"
    if key == "iso": return os.path.basename(c.get("paths", "iso"))
    if key == "large": return "installed" if os.path.isdir(os.path.join(WORK, "vosk", LARGE_MODEL)) else ""
    return ""


def activate(c, key, delta=1):
    """Toggle/cycle a setting. Returns True if changed."""
    if key.startswith("launch:"):
        k = key[7:]; c.set("launch", k, "0" if c.getboolean("launch", k) else "1")
    elif key.startswith("qol:"):
        k = key[4:]; q = next(q for q in QOL if q[0] == k)
        if not q[3]: return False
        if q[2] == "bool": c.set("qol", k, "0" if c.get("qol", k) == "1" else "1")
        else:
            vals = q[2][1]; i = vals.index(c.get("qol", k)) if c.get("qol", k) in vals else 0
            c.set("qol", k, vals[(i + delta) % len(vals)])
    elif key == "iso":
        isos = find_isos(c); cur = c.get("paths", "iso")
        i = isos.index(cur) if cur in isos else -1
        c.set("paths", "iso", isos[(i + delta) % len(isos)])
    else: return False
    save(c); return True


def run_ui():
    import pygame
    os.environ.setdefault("SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD", "1")
    pygame.init(); pygame.joystick.init()
    full = os.environ.get("SteamDeck") == "1" or os.environ.get("XDG_CURRENT_DESKTOP") == "gamescope" or "--fullscreen" in sys.argv
    scr = pygame.display.set_mode((1280, 800), pygame.FULLSCREEN if full else pygame.RESIZABLE)
    pygame.display.set_caption("Lifeline Recomp Launcher"); pygame.mouse.set_visible(False)
    pads = {}
    def font(sz): return pygame.font.Font(None, sz)
    F, S, T = font(40), font(28), font(64)
    c, sel, job, msg, clock, rep = load(), 0, None, "", pygame.time.Clock(), 0
    def act(name):
        nonlocal job, msg, sel
        items = menu_items(c); key, _, en = items[sel]
        if job and not job.done: return
        if job and job.done:
            if name in ("a", "b"): job = None
            return
        if name == "b": return "quit"
        if name in ("left", "right") and key.startswith(("qol:", "iso")):
            activate(c, key, -1 if name == "left" else 1); return
        if name == "start": key, en = "play", items[0][2]
        if name != "a" and name != "start": return
        if not en:
            msg = "Coming soon" if key.startswith("qol:") else "Install first"; return
        if key in ("play", "new"):
            pygame.display.quit()
            r = subprocess.call(play_cmd(c, new_game=(key == "new")), env=play_env(c))
            return "quit" if r == 0 else "relaunch"
        if key == "install": job = Job("Install / update", lambda j: install(j, c))
        elif key == "large": job = Job("Large speech model", lambda j: download_large(j, c))
        elif key == "quit": return "quit"
        else: activate(c, key)
    while True:
        for e in pygame.event.get():
            r = None
            if e.type == pygame.QUIT: return 0
            if e.type == pygame.CONTROLLERDEVICEADDED:
                try: pads[e.device_index] = pygame._sdl2.controller.Controller(e.device_index)
                except Exception: pass
            if e.type == pygame.JOYDEVICEADDED and not pads:
                pads[e.device_index] = pygame.joystick.Joystick(e.device_index)
            name = None
            if e.type == pygame.CONTROLLERBUTTONDOWN:
                name = {pygame.CONTROLLER_BUTTON_A: "a", pygame.CONTROLLER_BUTTON_B: "b", pygame.CONTROLLER_BUTTON_START: "start",
                        pygame.CONTROLLER_BUTTON_DPAD_UP: "up", pygame.CONTROLLER_BUTTON_DPAD_DOWN: "down",
                        pygame.CONTROLLER_BUTTON_DPAD_LEFT: "left", pygame.CONTROLLER_BUTTON_DPAD_RIGHT: "right"}.get(e.button)
            elif e.type == pygame.CONTROLLERAXISMOTION and e.axis in (0, 1) and abs(e.value) > 20000 and time.time() > rep:
                rep = time.time() + 0.2
                name = ("right" if e.value > 0 else "left") if e.axis == 0 else ("down" if e.value > 0 else "up")
            elif e.type == pygame.JOYHATMOTION and not any(hasattr(p, "as_joystick") for p in pads.values()):
                name = {(0, 1): "up", (0, -1): "down", (-1, 0): "left", (1, 0): "right"}.get(e.value)
            elif e.type == pygame.KEYDOWN:
                name = {pygame.K_UP: "up", pygame.K_DOWN: "down", pygame.K_LEFT: "left", pygame.K_RIGHT: "right",
                        pygame.K_RETURN: "a", pygame.K_SPACE: "a", pygame.K_ESCAPE: "b", pygame.K_BACKSPACE: "b", pygame.K_p: "start"}.get(e.key)
            if not name: continue
            msg = ""
            n = len(menu_items(c))
            if name == "up" and not job: sel = (sel - 1) % n
            elif name == "down" and not job: sel = (sel + 1) % n
            else: r = act(name)
            if r == "quit": return 0
            if r == "relaunch":
                scr = pygame.display.set_mode((1280, 800), pygame.FULLSCREEN if full else pygame.RESIZABLE)
        W, H = scr.get_size(); scr.fill((12, 14, 18))
        scr.blit(T.render("LIFELINE RECOMP", True, (220, 60, 50)), (60, 30))
        if job:
            scr.blit(F.render(job.title + ("  - running..." if not job.done else ("  - OK" if job.ok else "  - FAILED")), True, (240, 240, 240)), (60, 110))
            y = 160
            for l in job.lines[-((H - 220) // 30):]:
                scr.blit(S.render(l[:110], True, (180, 190, 200)), (60, y)); y += 30
            if job.done: scr.blit(F.render("A / B: back", True, (120, 200, 120)), (60, H - 60))
        else:
            items = menu_items(c); rowh = 38; top = 110
            first = max(0, min(sel - 6, len(items) - (H - 200) // rowh))
            for i, (key, lbl, en) in enumerate(items[first:first + (H - 200) // rowh], first):
                y = top + (i - first) * rowh
                if i == sel: pygame.draw.rect(scr, (50, 60, 80), (40, y - 4, W - 80, rowh))
                col = (240, 240, 240) if en else (110, 110, 110)
                scr.blit(F.render(lbl, True, col), (60, y))
                v = value_of(c, key) if en or not key.startswith("qol:") else "coming soon"
                scr.blit(F.render(v, True, (120, 200, 255) if en else (110, 110, 110)), (W - 360, y))
            key = items[sel][0]
            hint = next((q[4] for q in QOL if "qol:" + q[0] == key), "")
            scr.blit(S.render(msg or hint, True, (230, 200, 90)), (60, H - 90))
            scr.blit(S.render("D-pad: move   A: select   </>: change   START: play   B: quit", True, (140, 140, 140)), (60, H - 50))
        pygame.display.flip(); clock.tick(30)


def main():
    a = sys.argv[1:]
    c = load()
    if "--set" in a:
        for i, x in enumerate(a):
            if x == "--set":
                k, v = a[i + 1].split("=", 1); s, o = k.split(".", 1); c.set(s, o, v)
        save(c); return 0
    if "--print-config" in a:
        if not os.path.exists(CFG): save(c)
        print(open(CFG).read()); return 0
    if "--dry-run" in a:
        print(" ".join(shlex.quote(x) for x in play_cmd(c, "--new-game" in a))); return 0
    if not os.path.exists(CFG): save(c)
    return run_ui()


if __name__ == "__main__":
    sys.exit(main())
