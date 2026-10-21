#!/usr/bin/env python3
"""Lifeline Recomp launcher: install/update from your own ISO, QoL toggles, launch.

Controller-first (SDL GameController via pygame): D-pad/left stick = move, A = select/toggle,
B = back, START = play. Keyboard: arrows, Enter, Esc. Works in SteamOS Game Mode as a non-Steam game.

Headless helpers (no window):
  lifeline_launcher.py --print-config        show config.ini as run.sh will see it
  lifeline_launcher.py --dry-run             print the run.sh command that PLAY would execute
  lifeline_launcher.py --set qol.resolution_scale=2 [--set ...]   edit config and exit
Windows (os.name == "nt", started by windows/launcher.cmd / launcher.ps1 from game/launcher-venv): the same app, with
run.ps1 / build.ps1 / install.ps1 in place of run.sh / build.sh, and the install root %USERPROFILE%/Lifeline/game.
Every Windows difference is behind WIN below; the Linux code paths are unchanged.
Contains only our code; never bundles game data.
"""
import argparse, configparser, re, hashlib, glob, os, shlex, subprocess, sys, tempfile, threading, time, urllib.request, zipfile, shutil

WIN = os.name == "nt"
HOME = os.path.expanduser("~")   # %USERPROFILE% on Windows
WORK = os.environ.get("LIFELINE_WORK", os.path.join(HOME, "Lifeline", "game") if WIN else os.path.join(HOME, "lifeline-recomp"))
CFG = os.path.join(WORK, "config.ini")
HERE = os.path.dirname(os.path.abspath(__file__))
RUN_SCRIPT = "run.ps1" if WIN else "run.sh"
ENV_FILE = "lifeline.env.json" if WIN else "lifeline.env"   # written by build.ps1 + install.ps1 / build.sh
DEFAULT_ISO = os.path.join(HOME, "Downloads", "Life Line (USA).iso")
LARGE_MODEL = "vosk-model-en-us-0.22"
# sha256 of the zip we tested (computed from the real download on 2026-10-13)
LARGE_MODEL_SHA = "47f9a81ebb039dbb0bd319175c36ac393c0893b796c2b6303e64cf58c27b69f6"
LARGE_MODEL_NEED_MB = 1800 + 2900   # zip + unpacked
SMALL_MODEL = "vosk-model-small-en-us-0.15"

# key, label, kind ('bool' or ('choice', values)), available now?, one-line help
QOL = [
    ("voice_readout",    "1 On-screen voice readout",   "bool", False, "Shows what was heard + match/reject (PS2_VOICE_OVERLAY)"),
    ("voice_tuning",     "2 Voice tuning config",       "bool", False, "Reads voice.ini at launch (PS2_VOICE_CONFIG)"),
    ("resolution_scale", "3 Internal resolution",       ("choice", ["1", "2", "3"]), True, "PS2_SCALE: 1 = native, 2-3 = sharper (AA coming soon)"),
    ("save_slots",       "4 Save-anywhere slots",       "bool", True,  "4 save-state slots: F5 / Select+R1 save, F8 / hold Select+L1 load, F6 / Select+Right slot"),
    ("always_on",        "5 Always-on listening",       "bool", False, "Voice activity presses talk for you (PS2_VOICE_ALWAYS_ON)"),
    ("large_model",      "6 Large speech model",        "bool", False, "Uses %s if downloaded (better names, slower)" % LARGE_MODEL),
    ("widescreen",       "7 Native widescreen",         "bool", True,  "16:9 hor+: wider 3D view; 2D HUD/menus are stretched (PS2_WIDESCREEN)"),
    ("faster_loads",     "8 Faster loads / 60fps",      "bool", False, "Faster loading screens and a 60 fps option"),
    ("vu_fast",          "9 Faster VU interpreter",     "bool", True,  "Faster vector-unit interpreter, same results; off = original (PS2_VU_FAST)"),
    ("button_icons",     "10 Button icons",             ("choice", ["ps2", "xbox", "deck"]), True, "On-screen button glyphs: PS2 (original), Xbox or Steam Deck (PS2_ICON_PACK)"),
    # Available now, but off in a fresh config.ini (DEFAULTS below): opt in.
    ("fast_forward",     "11 Fast-forward (hold)",      "bool", True,  "Hold Tab or Select+R2 to run up to 4x (PS2_FF_MAX); not while talking"),
    ("fmv_skip",         "12 Skip movies",              "bool", True,  "Start ends a movie (FMV) early; not while a voice command is in progress (PS2_FMV_SKIP)"),
]
# [build] options change the compiled binary: they take effect on the next Install / update.
BUILD = [("cpu_tuned", "CPU-tuned build (rebuild)",
          "-march=native + LTO for this machine's CPU. Applied by Install / update (rebuild); generic if LTO fails")]
LAUNCH = [("skip_tutorial", "Skip tutorial (needs saves/room001.state)"),
          ("fullscreen", "Fullscreen"), ("debug", "Debug logs"), ("voice_off", "Voice off (PS2_VOICE_OFF)")]
DEFAULTS = {"launch": {"skip_tutorial": "0", "fullscreen": "1", "debug": "1", "voice_off": "0"},
            "qol": {k: {"resolution_scale": "1", "button_icons": "ps2"}.get(k, "0") for k, *_ in QOL},   # save_slots stays off until turned on
            "build": {k: "0" for k, *_ in BUILD},
            "paths": {"iso": DEFAULT_ISO, "kit": os.path.dirname(HERE)}}


def load():
    c = configparser.ConfigParser(inline_comment_prefixes=("#", ";"))   # ' # note' after a value is a comment
    c.read_dict(DEFAULTS)
    c.read(CFG)
    return c


def save(c):
    os.makedirs(WORK, exist_ok=True)
    tmp = CFG + ".tmp"
    with open(tmp, "w") as f:
        f.write("# Lifeline Recomp launcher config; %s reads [qol]. 'coming soon' items are reserved.\n" % RUN_SCRIPT)
        c.write(f)
    os.replace(tmp, CFG)


def powershell():
    """Windows PowerShell 5.1 (always present), else PowerShell 7 (pwsh)."""
    return shutil.which("powershell") or shutil.which("pwsh") or "powershell"


def ps_file(script):
    """argv prefix that runs a .ps1 file: unsigned scripts are fine, the user profile is not loaded."""
    return [powershell(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script]


def show_cmd(cmd):
    """A command line as the user would type it (cmd.exe quoting on Windows, sh quoting elsewhere)."""
    return subprocess.list2cmdline(cmd) if WIN else " ".join(shlex.quote(x) for x in cmd)


def play_cmd(c, new_game=False):
    a = ps_file(os.path.join(WORK, "run.ps1")) if WIN else [os.path.join(WORK, "run.sh")]
    if not new_game and c.getboolean("launch", "skip_tutorial"): a.append("--skip-tutorial")
    if c.getboolean("launch", "debug"): a.append("--debug")
    if c.getboolean("launch", "fullscreen"): a.append("--fullscreen")
    return a


def running_ps2run():
    """pids of running ps2run processes, only looked at, never stopped (the user closes the game). [] if none or if
    the check cannot run. Windows: tasklist (no /proc). Linux: pgrep -x ps2run (distrobox shares the host's process list)."""
    if WIN:
        try:
            r = subprocess.run(["tasklist", "/FI", "IMAGENAME eq ps2run.exe", "/FO", "CSV", "/NH"], capture_output=True, text=True,
                               errors="replace", timeout=15, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except (OSError, subprocess.SubprocessError): return []
        pids = []
        for line in r.stdout.splitlines():   # "ps2run.exe","1234","Console","1","123,456 K"; no match prints an INFO line
            f = [x.strip('"') for x in line.strip().split('","')]
            if len(f) > 1 and f[0].lower() == "ps2run.exe" and f[1].isdigit(): pids.append(int(f[1]))
        return pids
    try:
        r = subprocess.run(["pgrep", "-x", "ps2run"], capture_output=True, text=True, errors="replace", timeout=15)
    except (OSError, subprocess.SubprocessError): return []
    return [int(x) for x in r.stdout.split() if x.isdigit()]


def game_running_msg(pids):
    return "The game is already running (ps2run pid %s): close it first" % ", ".join(str(p) for p in pids)


def play_env(c):
    e = dict(os.environ)
    if c.getboolean("launch", "voice_off"): e.setdefault("PS2_VOICE_OFF", "1")   # exported env wins (as in run.sh)
    return e


def _flavor_lines():
    try: return open(os.path.join(WORK, "build-flavor")).read().splitlines()
    except OSError: return []


def built_flavor():
    """Flavor of the installed ps2run as written by build.sh (cpu_tuned | generic | generic-fallback), or None."""
    lines = _flavor_lines()
    return (lines[0].strip() or None) if lines else None


def built_cpu():
    """CPU model the installed build was made on ('cpu=' line of build-flavor), or None (older builds)."""
    return next((l[4:].strip() for l in _flavor_lines() if l.startswith("cpu=")), None) or None


def _win_cpu():
    """CPU model from the registry (Windows has no /proc/cpuinfo)."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0") as k:
            return str(winreg.QueryValueEx(k, "ProcessorNameString")[0]).strip() or None
    except (ImportError, OSError): return None


def current_cpu():
    if WIN and not os.environ.get("LIFELINE_CPUINFO"): return _win_cpu()
    try:
        with open(os.environ.get("LIFELINE_CPUINFO", "/proc/cpuinfo")) as f:
            return next((l.split(":", 1)[1].strip() for l in f if l.startswith("model name")), None)
    except OSError: return None


def cpu_change_msg():
    return "CPU changed (%s -> %s): run Install / update to rebuild the CPU-tuned build" % (built_cpu(), current_cpu())


def cpu_changed():
    """A CPU-tuned build made on another CPU model: -march=native code may not run here (illegal instruction)."""
    if built_flavor() != "cpu_tuned": return False
    have, now = built_cpu(), current_cpu()
    return bool(have and now and have != now)


def wanted_flavor(c):
    return "cpu_tuned" if c.getboolean("build", "cpu_tuned") else "generic"


def rebuild_pending(c):
    """True when [build] settings differ from what is installed (only once something is installed)."""
    if WIN: return False   # build.ps1 has no [build] options yet (no build-flavor file): nothing to rebuild for
    if not os.path.isfile(os.path.join(WORK, ENV_FILE)): return False
    have = built_flavor() or "generic"          # builds made before this option were generic
    if have == "generic-fallback": have = "generic" if wanted_flavor(c) == "generic" else "fallback"
    return have != wanted_flavor(c) or cpu_changed()


def build_env(c):
    e = dict(os.environ)
    e["CPU_TUNED"] = "1" if c.getboolean("build", "cpu_tuned") else "0"
    return e


def _env_json_kit():
    """KIT recorded by install.ps1 in lifeline.env.json (our repo checkout), or None."""
    import json
    try:
        with open(os.path.join(WORK, "lifeline.env.json"), encoding="utf-8-sig") as f: v = json.load(f).get("KIT")
    except (OSError, ValueError, AttributeError): return None
    return v if isinstance(v, str) and v else None


def kit_dir(c):
    """Folder with the build script: steam-machine/ (build.sh) on Linux, windows/ (build.ps1 + install.ps1) on Windows."""
    k = c.get("paths", "kit")
    if WIN:
        cands = [k, os.path.join(k, "windows"), os.path.join(os.path.dirname(k), "windows")]
        rk = _env_json_kit()
        if rk: cands.append(os.path.join(rk, "windows"))
        cands.append(os.path.join(HOME, "Lifeline", "src", "lifeline-recomp", "windows"))
        for cand in cands:
            if os.path.isfile(os.path.join(cand, "build.ps1")) and os.path.isfile(os.path.join(cand, "install.ps1")): return cand
        return k
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
        self.lock = threading.Lock()
        self.log_path, self._f = None, None
        threading.Thread(target=self._run, args=(fn,), daemon=True).start()

    def open_log(self, kind):
        """Tee everything to ~/lifeline-recomp/logs/<kind>-YYYYMMDD-HHMMSS.log."""
        d = os.path.join(WORK, "logs"); os.makedirs(d, exist_ok=True)
        base = os.path.join(d, "%s-%s" % (kind, time.strftime("%Y%m%d-%H%M%S")))
        self.log_path = base + ".log"
        try: self._f = open(self.log_path, "x", buffering=1, errors="replace")
        except FileExistsError:
            self.log_path = "%s-%06d-%d.log" % (base, int(time.time() * 1e6) % 1000000, os.getpid())
            self._f = open(self.log_path, "x", buffering=1, errors="replace")
        self._f.write("== %s  %s\n" % (self.title, time.strftime("%Y-%m-%d %H:%M:%S %z")))

    def file(self, s):   # log file only (full command output)
        if self._f:
            with self.lock: self._f.write(s.rstrip("\n") + "\n")

    def log(self, s):
        with self.lock:
            self.lines.append(s.rstrip()); self.lines[:] = self.lines[-400:]
            if self._f: self._f.write(s.rstrip("\n") + "\n")

    def tail(self, n):
        with self.lock: return list(self.lines[-n:])

    def _run(self, fn):
        try: self.ok = bool(fn(self))
        except Exception as ex:
            import traceback
            self.log("ERROR: %s" % ex); self.file(traceback.format_exc()); self.ok = False
        if self._f:
            self.log("== result: %s" % ("OK" if self.ok else "FAILED"))
            if not self.ok: self.log("Full log: " + self.log_path)
            self._f.close(); self._f = None
        self.done = True


def _stream(job, cmd, progress=None, env=None):
    """Run cmd with stderr merged into stdout. With a progress file, show its phase lines while
    running; on failure always show the last lines of the command's own output."""
    job.log("$ " + show_cmd(cmd))
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", env=env)
    seen = len(open(progress, errors="replace").read().splitlines()) if progress and os.path.exists(progress) else 0
    out = []
    for line in p.stdout:
        job.file("  | " + line)
        out.append(line.rstrip()); out[:] = out[-40:]
        if progress and os.path.exists(progress):
            with open(progress, errors="replace") as f: pl = f.read().splitlines()
            for l in pl[seen:]: job.log(l)
            seen = len(pl)
        elif not progress: job.log(line)
    ok = p.wait() == 0
    job.file("  exit %d" % p.returncode)
    if not ok:
        job.log("--- failed (exit %d), last output:" % p.returncode)
        for l in out[-20:]: job.log(l)
    return ok


def _install_file(src, dst):
    """Copy src to dst atomically (tmp + rename). Skips when they are the same file, which is the
    case when Install/update runs from the installed launcher (~/lifeline-recomp/launcher)."""
    if os.path.exists(dst) and os.path.samefile(src, dst): return False
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst) or ".", prefix="." + os.path.basename(dst) + ".", suffix=".tmp")
    os.close(fd)
    try:
        shutil.copy2(src, tmp)
        os.replace(tmp, dst)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
    return True


def _write_atomic(path, data):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def install_win(job, c, kit, iso):
    """Windows: build.ps1 (ps2run.exe, lifeline.env.json), then install.ps1 (Vosk, model, voice assets, aliases with this
    Python (no -PyArgs: powershell -File drops empty arguments), run.ps1, icons, launcher files, launcher-venv only if missing). Same log/progress handling as Linux."""
    prog = os.path.join(WORK, "build-progress.log")
    job.log("Building from your ISO (progress: build-progress.log)")
    if c.getboolean("build", "cpu_tuned"): job.log("Note: cpu_tuned is not applied on Windows yet (build.ps1 builds generic)")
    if not _stream(job, ps_file(os.path.join(kit, "build.ps1")) + ["-Iso", iso, "-Work", WORK], progress=prog):
        job.log("build.ps1 failed; full log: " + job.log_path); return False
    job.log("Installing voice files, run.ps1 and the launcher (install.ps1) ...")
    if not _stream(job, ps_file(os.path.join(kit, "install.ps1")) + ["-Iso", iso, "-Root", WORK, "-PyExe", sys.executable]):
        job.log("install.ps1 failed; full log: " + job.log_path); return False
    job.log("Done.")
    return True


def install(job, c):
    job.open_log("install")
    kit, iso = kit_dir(c), c.get("paths", "iso")
    job.file("kit=%s iso=%s work=%s launcher=%s cwd=%s python=%s" % (kit, iso, WORK, HERE, os.getcwd(), sys.executable))
    if not os.path.isfile(iso): job.log("ISO not found: " + iso); return False
    pids = running_ps2run()   # build.sh / build.ps1 would replace the running ps2run
    if pids: job.log(game_running_msg(pids) + "; nothing was changed"); return False
    local = os.path.join(WORK, "voice-assets", "aliases.local.tsv")
    keep = open(local, "rb").read() if os.path.exists(local) else None
    try:
        if WIN: return install_win(job, c, kit, iso)
        prog = os.path.join(WORK, "build-progress.log")
        job.log("Building from your ISO (progress: build-progress.log, full: build.log)")
        env = build_env(c)
        job.log("Build options: cpu_tuned=%s (CPU_TUNED=%s; flags: %s)" % (c.get("build", "cpu_tuned"), env["CPU_TUNED"],
                "-march=native -flto=thin, linker -fuse-ld=lld" if env["CPU_TUNED"] == "1" else "generic"))
        if not _stream(job, ["bash", os.path.join(kit, "build.sh"), iso, WORK], progress=prog, env=env):
            job.log("build.sh failed; full log: " + os.path.join(WORK, "build.log")); return False
        fl = built_flavor()
        job.log("Built flavor: %s" % (fl or "unknown"))
        if fl == "generic-fallback": job.log("CPU-tuned build failed, fell back to generic (see build.log)")
        job.log("Building spoken-form aliases ...")
        tool = os.path.join(os.path.dirname(kit), "voice", "tools", "build_aliases.py")
        cmd = ["python3", tool, "--assets", os.path.join(WORK, "voice-assets"), "--model", os.path.join(WORK, "vosk", SMALL_MODEL)]
        if shutil.which("distrobox") and not os.path.exists("/run/.containerenv"): cmd = ["distrobox", "enter", "lifeline-build", "--"] + cmd
        ok = _stream(job, cmd)
        job.log("Installing run.sh and the launcher ...")
        _install_file(os.path.join(kit, "run.sh"), os.path.join(WORK, "run.sh"))
        if os.path.isfile(os.path.join(kit, "vu-check.sh")):   # vu_fast check tool (older kits lack it)
            _install_file(os.path.join(kit, "vu-check.sh"), os.path.join(WORK, "vu-check.sh"))
        inst = os.path.join(WORK, "launcher"); os.makedirs(inst, exist_ok=True)
        src = os.path.join(kit, "launcher") if os.path.isdir(os.path.join(kit, "launcher")) else HERE   # prefer the kit's (newer) copy
        for f in ("lifeline_launcher.py", "bindings.py", "launcher.sh"):
            job.file("  %s %s" % ("installed" if _install_file(os.path.join(src, f), os.path.join(inst, f)) else "already current (same file)", f))
        req = os.path.join(os.path.dirname(kit), "windows", "launcher-requirements.txt")   # pinned pygame-ce, shared with Windows
        if os.path.isfile(req):
            job.file("  %s launcher-requirements.txt" % ("installed" if _install_file(req, os.path.join(inst, "launcher-requirements.txt")) else "already current (same file)"))
        job.log("Done." if ok else "Aliases step failed (game still playable).")
        return True
    finally:   # never lose the user's own alias fixes, whatever happened above
        if keep is not None and (not os.path.exists(local) or open(local, "rb").read() != keep):
            os.makedirs(os.path.dirname(local), exist_ok=True)
            _write_atomic(local, keep); job.log("restored aliases.local.tsv")


def download_large(job, c):
    job.open_log("download")
    d = os.path.join(WORK, "vosk"); os.makedirs(d, exist_ok=True)
    if os.path.isdir(os.path.join(d, LARGE_MODEL)): job.log("Already downloaded."); return True
    free = shutil.disk_usage(d).free >> 20
    if free < LARGE_MODEL_NEED_MB:
        job.log("Not enough free space: %d MB free, need ~%d MB" % (free, LARGE_MODEL_NEED_MB)); return False
    url = "https://alphacephei.com/vosk/models/%s.zip" % LARGE_MODEL
    z = os.path.join(d, LARGE_MODEL + ".zip.part")
    job.log("Downloading " + url)
    try:
        h = hashlib.sha256()
        with urllib.request.urlopen(url, timeout=60) as r, open(z, "wb") as f:
            tot, got, last = int(r.headers.get("Content-Length") or 0), 0, 0
            while True:
                b = r.read(1 << 20)
                if not b: break
                f.write(b); h.update(b); got += len(b)
                if time.time() - last > 1:
                    last = time.time(); job.log("  %d MB%s" % (got >> 20, " / %d MB" % (tot >> 20) if tot else ""))
        if h.hexdigest() != LARGE_MODEL_SHA:
            job.log("sha256 mismatch (got %s); download discarded" % h.hexdigest()); return False
        job.log("Checksum OK. Unpacking ...")
        tmpd = os.path.join(d, ".unpack-" + LARGE_MODEL); shutil.rmtree(tmpd, ignore_errors=True)
        try:
            with zipfile.ZipFile(z) as zf: zf.extractall(tmpd)   # closed before the .part is removed (Windows locks open files)
            os.replace(os.path.join(tmpd, LARGE_MODEL), os.path.join(d, LARGE_MODEL))
        finally:
            shutil.rmtree(tmpd, ignore_errors=True)
        job.log("Done: " + os.path.join(d, LARGE_MODEL)); return True
    finally:
        if os.path.exists(z): os.remove(z)


# ---------------- UI ----------------
def menu_items(c):
    built = os.path.isfile(os.path.join(WORK, RUN_SCRIPT)) and os.path.isfile(os.path.join(WORK, ENV_FILE))
    m = [("play", "PLAY (continue / memory card)", built), ("new", "New game", built)]
    m += [("launch:" + k, lbl, True) for k, lbl in LAUNCH]
    m += [("qol:" + k, lbl, avail) for k, lbl, kind, avail, _ in QOL]
    if not WIN: m += [("build:" + k, lbl, True) for k, lbl, _ in BUILD]   # build.ps1 has no [build] options yet
    m += [("bindings", "Controller bindings", True), ("iso", "ISO", True), ("install", "Install / update from ISO", True),
          ("large", "Download large speech model (~1.8 GB)", True), ("quit", "Quit", True)]
    return m


def value_of(c, key):
    if key.startswith("launch:"): return "ON" if c.getboolean("launch", key[7:]) else "off"
    if key.startswith("qol:"):
        k = key[4:]; kind = next(q[2] for q in QOL if q[0] == k)
        if kind == "bool": return "ON" if c.get("qol", k) == "1" else "off"
        return c.get("qol", k) + ("x" if k == "resolution_scale" else "")
    if key.startswith("build:"):
        v = "ON" if c.getboolean("build", key[6:]) else "off"
        if key == "build:cpu_tuned" and cpu_changed(): v += " (rebuild: new CPU)"
        elif rebuild_pending(c): v += " (rebuild)"
        elif key == "build:cpu_tuned" and built_flavor() == "generic-fallback": v += " (fell back)"
        return v
    if key == "bindings": return "custom" if c.has_section("bindings") else "default"
    if key == "iso": return os.path.basename(c.get("paths", "iso"))
    if key == "large": return "installed" if os.path.isdir(os.path.join(WORK, "vosk", LARGE_MODEL)) else ""
    return ""


ICON_NAME = re.compile(r"^[A-Za-z0-9_-]+$")   # same rule as run.sh for a [qol] button_icons pack name


def choices(c, k):
    """Values a choice item cycles through. For button_icons this adds installed packs (icons.local/<name> or
    icons/<name> with an icons.txt) and a custom value already in config.ini, so saving never drops it; a
    hand-set name with no pack on disk is kept until you cycle away from it."""
    vals = list(next(q for q in QOL if q[0] == k)[2][1])
    if k != "button_icons": return vals
    for d in ("icons.local", "icons"):   # run.sh looks in icons.local/ first, then the shipped icons/
        root = os.path.join(WORK, d)
        if not os.path.isdir(root): continue
        for n in sorted(os.listdir(root)):
            if ICON_NAME.match(n) and os.path.isfile(os.path.join(root, n, "icons.txt")) and n not in vals: vals.append(n)
    cur = c.get("qol", k)
    if cur not in vals and ICON_NAME.match(cur): vals.append(cur)
    return vals


def activate(c, key, delta=1):
    """Toggle/cycle a setting. Returns True if changed."""
    if key.startswith("launch:"):
        k = key[7:]; c.set("launch", k, "0" if c.getboolean("launch", k) else "1")
    elif key.startswith("qol:"):
        k = key[4:]; q = next(q for q in QOL if q[0] == k)
        if not q[3]: return False
        if q[2] == "bool": c.set("qol", k, "0" if c.get("qol", k) == "1" else "1")
        else:
            vals = choices(c, k); i = vals.index(c.get("qol", k)) if c.get("qol", k) in vals else 0
            c.set("qol", k, vals[(i + delta) % len(vals)])
    elif key.startswith("build:"):
        k = key[6:]; c.set("build", k, "0" if c.getboolean("build", k) else "1")
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
    full = (os.environ.get("SteamDeck") == "1" or os.environ.get("XDG_CURRENT_DESKTOP") == "gamescope"
            or bool(os.environ.get("GAMESCOPE_WAYLAND_DISPLAY")) or "--fullscreen" in sys.argv)
    if WIN and os.environ.get("SteamTenfoot") == "1": full = True   # Steam Big Picture on Windows (to verify on the PC)
    scr = pygame.display.set_mode((1280, 800), pygame.FULLSCREEN if full else pygame.RESIZABLE)
    pygame.display.set_caption("Lifeline Recomp Launcher"); pygame.mouse.set_visible(False)
    pads = {}
    def font(sz): return pygame.font.Font(None, sz)
    F, S, T = font(40), font(28), font(64)
    c, sel, job, msg, clock, rep = load(), 0, None, "", pygame.time.Clock(), 0
    if cpu_changed():   # prompt once at start: the tuned build was made for another CPU
        msg = cpu_change_msg()
    def act(name):
        nonlocal job, msg, sel
        items = menu_items(c); key, _, en = items[sel]
        if job and not job.done: return
        if job and job.done:
            if name in ("a", "b"): job = None
            return
        if name == "b": return "quit"
        if name in ("left", "right") and key.startswith(("qol:", "iso", "build:")):
            activate(c, key, -1 if name == "left" else 1)
            if key.startswith("build:") and rebuild_pending(c): msg = "Rebuild needed: run Install / update to apply"
            return
        if name == "start": key, en = "play", items[0][2]
        if name != "a" and name != "start": return
        if not en:
            msg = "Coming soon" if key.startswith("qol:") else "Install first"; return
        if key in ("play", "new"):
            pids = running_ps2run()   # a second instance would share saves/ and the memory card; never stop the running one
            if pids: msg = game_running_msg(pids); return
            pygame.display.quit()
            r = subprocess.call(play_cmd(c, new_game=(key == "new")), env=play_env(c))   # waits for the game
            msg = "" if r == 0 else "Game exited with code %d (%s --debug logs to logs/run-*.log)" % (r, RUN_SCRIPT)
            return "relaunch"   # back to the menu either way (the in-game quit hotkey exits 0)
        if key == "bindings":
            import bindings
            bindings.screen(pygame, scr, (F, S, T), c, save); pygame.event.clear(); return
        if key == "install": job = Job("Install / update", lambda j: install(j, c))
        elif key == "large": job = Job("Large speech model", lambda j: download_large(j, c))
        elif key == "quit": return "quit"
        else: activate(c, key)
        if key.startswith("build:") and rebuild_pending(c): msg = "Rebuild needed: run Install / update to apply"
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
            if r == "relaunch":   # game exited: back to the menu, drop presses made in-game
                pygame.display.init(); pygame.joystick.quit(); pygame.joystick.init(); pads.clear()
                scr = pygame.display.set_mode((1280, 800), pygame.FULLSCREEN if full else pygame.RESIZABLE)
                pygame.mouse.set_visible(False)
                for i in range(pygame.joystick.get_count()):
                    try: pads[i] = pygame._sdl2.controller.Controller(i)
                    except Exception: pads[i] = pygame.joystick.Joystick(i)
                pygame.event.clear(); rep = time.time() + 0.5
                break
        W, H = scr.get_size(); scr.fill((12, 14, 18))
        scr.blit(T.render("LIFELINE RECOMP", True, (220, 60, 50)), (60, 30))
        if job:
            scr.blit(F.render(job.title + ("  - running..." if not job.done else ("  - OK" if job.ok else "  - FAILED")), True, (240, 240, 240)), (60, 110))
            y = 160
            for l in job.tail((H - 220) // 30):
                scr.blit(S.render(l[:110], True, (180, 190, 200)), (60, y)); y += 30
            if job.done:
                if not job.ok and job.log_path: scr.blit(S.render("Log: " + job.log_path, True, (230, 120, 100)), (60, H - 95))
                scr.blit(F.render("A / B: back", True, (120, 200, 120)), (60, H - 60))
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
            hint = next((q[4] for q in QOL if "qol:" + q[0] == key), "") or next((b[2] for b in BUILD if "build:" + b[0] == key), "")
            if key == "install" and rebuild_pending(c): hint = "Build settings changed: Install / update rebuilds with them"
            scr.blit(S.render(msg or hint, True, (230, 200, 90)), (60, H - 90))
            scr.blit(S.render("D-pad: move   A: select   </>: change   START: play   B: quit", True, (140, 140, 140)), (60, H - 50))
        pygame.display.flip(); clock.tick(30)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Lifeline Recomp launcher")
    ap.add_argument("--set", action="append", default=[], metavar="SECTION.KEY=VALUE", help="edit config.ini and exit")
    ap.add_argument("--print-config", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="print the run.sh command PLAY would run")
    ap.add_argument("--new-game", action="store_true", help="with --dry-run: the New game command")
    ap.add_argument("--reset-bindings", action="store_true", help="drop [bindings] (built-in layout) and exit")
    ap.add_argument("--fullscreen", action="store_true", help="force a fullscreen launcher window")
    a = ap.parse_args(argv)
    c = load()
    if a.set:
        for x in a.set:
            k, sep, v = x.partition("=")
            sec, dot, opt = k.partition(".")
            if sec == "bindings" and sep and dot:
                import bindings
                bad = bindings.validate(opt, v)
                if bad: ap.error("--set bindings.%s: %s" % (opt, bad))
                v = bindings.strip_comment(v) or "none"
                bindings.set_binding(c, opt, v)
                w = bindings.push_to_talk_warning(c, opt)
                if w: print(w, file=sys.stderr)
                continue
            if not sep or not dot or not c.has_section(sec): ap.error("bad --set %r (want section.key=value)" % x)
            c.set(sec, opt, v)
        save(c); return 0
    if a.reset_bindings:
        import bindings; bindings.reset(c); save(c); return 0
    if a.print_config:
        if not os.path.exists(CFG): save(c)
        print(open(CFG).read())
        on_file = configparser.ConfigParser(inline_comment_prefixes=("#", ";")); on_file.read(CFG)
        for sec in DEFAULTS:   # defaults not written in the file are still in effect: show them as comments
            missing = [k for k in DEFAULTS[sec] if not on_file.has_option(sec, k)]
            if missing: print("# defaults in effect (not in config.ini): " + ", ".join("%s.%s = %s" % (sec, k, c.get(sec, k)) for k in missing))
        return 0
    if a.dry_run:
        print(show_cmd(play_cmd(c, a.new_game))); return 0
    if not os.path.exists(CFG): save(c)
    return run_ui()


if __name__ == "__main__":
    sys.exit(main())
