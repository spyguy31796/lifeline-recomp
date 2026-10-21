"""Windows branches of the launcher, run on Linux by simulating Windows (os.name == "nt", sys.platform == "win32") at
import time. Checks: install root under %USERPROFILE%/Lifeline/game, PLAY via powershell -File run.ps1, install via
build.ps1 + install.ps1 (aliases.local.tsv restored byte for byte), kit search, CPU from winreg (no /proc), the large
model download, gamepad PLAY through pygame/SDL (dummy video) and no POSIX-only calls. Paths use the host separator here;
the real Windows run is on a Windows 10/11 PC. Run: python3 test_windows.py"""
import ast, builtins, hashlib, importlib, io, json, os, shutil, sys, tempfile, threading, time, types, zipfile, contextlib
HERE = os.path.dirname(os.path.abspath(__file__)); LAUNCHER = os.path.dirname(HERE)
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)

def load_win(home, work=None):
    """Import lifeline_launcher as on Windows: os.name/sys.platform are faked only while the module is imported."""
    saved = (os.name, sys.platform, os.environ.get("HOME"), os.environ.get("USERPROFILE"), os.environ.get("LIFELINE_WORK"))
    os.environ["HOME"] = home; os.environ["USERPROFILE"] = home
    if work is None: os.environ.pop("LIFELINE_WORK", None)
    else: os.environ["LIFELINE_WORK"] = work
    os.name = "nt"; sys.platform = "win32"
    try:
        sys.path.insert(0, LAUNCHER)
        for m in ("lifeline_launcher", "bindings"): sys.modules.pop(m, None)
        return importlib.import_module("lifeline_launcher")
    finally:
        sys.path.pop(0)
        os.name, sys.platform = saved[0], saved[1]
        for k, v in zip(("HOME", "USERPROFILE", "LIFELINE_WORK"), saved[2:]):
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v

@contextlib.contextmanager
def which(table):
    real = shutil.which; shutil.which = lambda n, *a, **k: table.get(n)
    try: yield
    finally: shutil.which = real

def run_job(L, fn):
    j = L.Job("t", fn)
    while not j.done: time.sleep(0.02)
    return j

PS51 = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
root = tempfile.mkdtemp(); home = os.path.join(root, "home")
os.makedirs(home)

# 1) install root and config path
L = load_win(home)
check(L.WIN, "WIN is set when os.name == 'nt'")
check(L.WORK == os.path.join(home, "Lifeline", "game"), "default install root = %%USERPROFILE%%/Lifeline/game: %s" % L.WORK)
check(L.CFG == os.path.join(home, "Lifeline", "game", "config.ini"), "config.ini under the install root")
check(L.RUN_SCRIPT == "run.ps1" and L.ENV_FILE == "lifeline.env.json", "run.ps1 + lifeline.env.json")
work = os.path.join(root, "My Games", "game")   # a space, as in many Windows paths
L = load_win(home, work)
check(L.WORK == work and L.CFG == os.path.join(work, "config.ini"), "LIFELINE_WORK still overrides")

# 2) PLAY: powershell -NoProfile -ExecutionPolicy Bypass -File run.ps1 (pwsh only when Windows PowerShell is missing)
c = L.load()
with which({"powershell": PS51, "pwsh": "pwsh.exe"}):
    cmd = L.play_cmd(c)
    check(cmd == [PS51, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(work, "run.ps1"), "--debug", "--fullscreen"], "play_cmd: %r" % cmd)
    c.set("launch", "skip_tutorial", "1"); c.set("launch", "debug", "0")
    check(L.play_cmd(c)[6:] == ["--skip-tutorial", "--fullscreen"], "skip_tutorial flag passed to run.ps1")
    check(L.play_cmd(c, new_game=True)[6:] == ["--fullscreen"], "New game never skips the tutorial")
with which({"pwsh": "/opt/pwsh/pwsh.exe"}):
    check(L.play_cmd(c)[0] == "/opt/pwsh/pwsh.exe", "no Windows PowerShell -> pwsh")
with which({}):
    check(L.play_cmd(c)[0] == "powershell", "nothing on PATH -> plain 'powershell'")
c = L.load()
with which({"powershell": PS51}):
    out = io.StringIO()
    with contextlib.redirect_stdout(out): rc = L.main(["--dry-run"])
    want = '%s -NoProfile -ExecutionPolicy Bypass -File "%s" --debug --fullscreen' % (PS51, os.path.join(work, "run.ps1"))
    check(rc == 0 and out.getvalue().strip() == want, "--dry-run prints a cmd.exe-quoted line: %r" % out.getvalue())
    check(not os.path.exists(L.CFG), "--dry-run writes nothing")

# 3) "built" = run.ps1 + lifeline.env.json (run.sh + lifeline.env do not count); no [build] items on Windows yet
os.makedirs(work, exist_ok=True)
for f in ("run.sh", "lifeline.env"): open(os.path.join(work, f), "w").close()
check(not L.menu_items(c)[0][2], "run.sh + lifeline.env do not make PLAY available on Windows")
for f in ("run.ps1", "lifeline.env.json"): open(os.path.join(work, f), "w").write("{}")
items = L.menu_items(c)
check(items[0][0] == "play" and items[0][2] and items[1][2], "run.ps1 + lifeline.env.json -> PLAY / New game enabled")
check(not any(k.startswith("build:") for k, _, _ in items), "no [build] items on Windows (build.ps1 has no options yet)")
c.set("build", "cpu_tuned", "1")
check(L.rebuild_pending(c) is False, "rebuild_pending is False on Windows")
c.set("build", "cpu_tuned", "0")
L.save(c)
check(open(L.CFG).readline().startswith("# Lifeline Recomp launcher config; run.ps1 reads [qol]."), "config.ini header names run.ps1")
L.activate(c, "launch:fullscreen"); check(L.load().get("launch", "fullscreen") == "0", "settings still saved to config.ini")
L.activate(c, "launch:fullscreen")

# 4) CPU model from winreg, never /proc
fake = types.ModuleType("winreg"); fake.HKEY_LOCAL_MACHINE = "HKLM"; opened = []
class _Key:
    def __enter__(self): return self
    def __exit__(self, *a): return False
def _open(h, p): opened.append((h, p)); return _Key()
fake.OpenKey = _open; fake.QueryValueEx = lambda k, n: ("AMD Ryzen 7 5800X3D 8-Core Processor  ", 1)
real_open = builtins.open
def guarded(f, *a, **k):
    if str(f).startswith("/proc"): raise AssertionError("opened " + str(f))
    return real_open(f, *a, **k)
sys.modules["winreg"] = fake; builtins.open = guarded
try:
    os.environ.pop("LIFELINE_CPUINFO", None)
    check(L.current_cpu() == "AMD Ryzen 7 5800X3D 8-Core Processor", "current_cpu from the registry")
    check(opened == [("HKLM", r"HARDWARE\DESCRIPTION\System\CentralProcessor\0")], "registry key: %r" % opened)
    fake.OpenKey = lambda h, p: (_ for _ in ()).throw(OSError("no key"))
    check(L.current_cpu() is None, "registry error -> None")
    check(L.cpu_changed() is False, "no build-flavor -> cpu_changed False")
finally:
    builtins.open = real_open; del sys.modules["winreg"]
ci = os.path.join(root, "cpuinfo"); open(ci, "w").write("model name\t: Test CPU\n"); os.environ["LIFELINE_CPUINFO"] = ci
check(L.current_cpu() == "Test CPU", "LIFELINE_CPUINFO still overrides (tests)"); del os.environ["LIFELINE_CPUINFO"]

# 4b) a running game is detected with tasklist (no /proc, no kill): parsing, and tasklist missing -> nothing blocks
ran = []
class R:
    def __init__(self, out): self.stdout, self.returncode = out, 0
def fake_run(out):
    def f(cmd, **k): ran.append(list(cmd)); return R(out)
    return f
real_run = L.subprocess.run
try:
    L.subprocess.run = fake_run('"ps2run.exe","4321","Console","1","812,004 K"\r\n"ps2run.exe","77","Console","1","1,000 K"\r\n')
    check(L.running_ps2run() == [4321, 77], "tasklist CSV -> ps2run pids")
    check(ran[-1][:3] == ["tasklist", "/FI", "IMAGENAME eq ps2run.exe"], "uses tasklist with an image-name filter: %r" % ran[-1])
    L.subprocess.run = fake_run("INFO: No tasks are running which match the specified criteria.\r\n")
    check(L.running_ps2run() == [], "no match (INFO line) -> []")
    L.subprocess.run = lambda cmd, **k: (_ for _ in ()).throw(FileNotFoundError("tasklist"))
    check(L.running_ps2run() is None, "tasklist cannot run -> None (check failed)")
    class R3:
        stdout, returncode = "ERROR: something", 1
    L.subprocess.run = lambda cmd, **k: (ran.append(list(cmd)), R3())[1]
    check(L.running_ps2run() is None, "tasklist error exit -> None")
    check(L.game_running_msg(None).startswith("Could not check whether the game is running (tasklist failed)"), "check-failed message names tasklist")
    check(all(c_[0] == "tasklist" for c_ in ran), "only tasklist is run (nothing is stopped): %r" % ran)
    check("4321" in L.game_running_msg([4321]) and "close it first" in L.game_running_msg([4321]), "friendly message names the pid")
finally:
    L.subprocess.run = real_run

# 5) kit search: windows/ with build.ps1 + install.ps1
repo = os.path.join(root, "src", "lifeline-recomp"); kitw = os.path.join(repo, "windows")
os.makedirs(os.path.join(repo, "steam-machine")); os.makedirs(kitw)
for f in ("build.ps1", "install.ps1"): open(os.path.join(kitw, f), "w").write("# stub\n")
c.set("paths", "kit", os.path.join(repo, "steam-machine")); check(L.kit_dir(c) == kitw, "repo steam-machine -> repo/windows")
c.set("paths", "kit", repo); check(L.kit_dir(c) == kitw, "repo root -> repo/windows")
c.set("paths", "kit", work)   # the installed launcher's default (dirname of game/launcher)
open(os.path.join(work, "lifeline.env.json"), "wb").write(b"\xef\xbb\xbf" + json.dumps({"KIT": repo, "ELF": "x"}).encode())
check(L.kit_dir(c) == kitw, "installed copy: KIT from lifeline.env.json (UTF-8 BOM ok)")
open(os.path.join(work, "lifeline.env.json"), "w").write("{bad json")
check(L.kit_dir(c) == work, "bad lifeline.env.json and no fallback -> the configured kit (install then reports it)")
hk = os.path.join(home, "Lifeline", "src", "lifeline-recomp", "windows"); os.makedirs(hk)
for f in ("build.ps1", "install.ps1"): open(os.path.join(hk, f), "w").close()
check(L.kit_dir(c) == hk, "fallback %USERPROFILE%/Lifeline/src/lifeline-recomp/windows")
shutil.rmtree(os.path.join(home, "Lifeline", "src"))

# 6) Install / update: build.ps1 then install.ps1 through PowerShell; aliases.local.tsv restored byte for byte
calls = os.path.join(root, "calls.jsonl")
stub = os.path.join(root, "fakeps.py")
open(stub, "w").write(r'''#!%s
import json, os, sys
a = sys.argv[1:]; open(%r, "a").write(json.dumps(a) + "\n")
script = os.path.basename(a[a.index("-File") + 1])
if script == "build.ps1":
    w = a[a.index("-Work") + 1]
    open(os.path.join(w, "build-progress.log"), "a").write("== [time 00:00:01] configure: 1s\n")
    print("build stdout"); sys.exit(int(os.environ.get("FAKE_BUILD_RC", "0")))
if script == "install.ps1":
    r = a[a.index("-Root") + 1]; os.makedirs(os.path.join(r, "voice-assets"), exist_ok=True)
    open(os.path.join(r, "voice-assets", "aliases.local.tsv"), "wb").write(b"CLOBBERED")
    print("install stdout"); sys.exit(int(os.environ.get("FAKE_INSTALL_RC", "0")))
sys.exit(9)
''' % (sys.executable, calls))
os.chmod(stub, 0o755)   # test scaffolding on the Linux host only
L.powershell = lambda: stub
L.running_ps2run = lambda: []   # game closed (tasklist itself is checked in 4b)
iso = os.path.join(root, "my disc.iso"); open(iso, "wb").close()
local = os.path.join(work, "voice-assets", "aliases.local.tsv"); os.makedirs(os.path.dirname(local), exist_ok=True)
mine = b"\xef\xbb\xbf# my fixes\r\nword\tother words\r\n"; open(local, "wb").write(mine)
c.set("paths", "kit", kitw); c.set("paths", "iso", iso)
seen_cmds = []
real_popen = L.subprocess.Popen
def spy(cmd, *a, **k): seen_cmds.append(list(cmd)); return real_popen(cmd, *a, **k)
L.subprocess.Popen = spy
try:
    j = run_job(L, lambda j: L.install(j, c))
    check(j.ok, "install ok: %s" % j.lines[-5:])
    got = [json.loads(l) for l in open(calls)]
    check(len(got) == 2, "two PowerShell runs: %r" % got)
    if len(got) == 2:
        check(got[0] == ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(kitw, "build.ps1"), "-Iso", iso, "-Work", work], "build.ps1 args: %r" % got[0])
        check(got[1] == ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(kitw, "install.ps1"), "-Iso", iso, "-Root", work, "-PyExe", sys.executable], "install.ps1 args (no empty -PyArgs): %r" % got[1])
    check(all(x[0] == stub for x in seen_cmds) and len(seen_cmds) == 2, "only PowerShell is run (no bash, python3, distrobox): %r" % seen_cmds)
    check(open(local, "rb").read() == mine, "aliases.local.tsv restored byte for byte after install.ps1 clobbered it")
    check(not [f for f in os.listdir(os.path.dirname(local)) if f.endswith(".tmp")], "no restore temp file left")
    check(any("configure: 1s" in l for l in j.lines) and any(l.startswith("$ " + stub) for l in j.lines), "progress lines + command shown")
    check(any('"%s"' % iso in l for l in j.lines if l.startswith("$ ")), "command line shown with cmd.exe quoting")
    log = open(j.log_path).read()
    check("build stdout" in log and "install stdout" in log and "restored aliases.local.tsv" in log, "install log has both outputs")
    for rcvar, want_calls in (("FAKE_BUILD_RC", 1), ("FAKE_INSTALL_RC", 2)):
        os.remove(calls); open(local, "wb").write(mine); os.environ[rcvar] = "3"
        try: j = run_job(L, lambda j: L.install(j, c))
        finally: del os.environ[rcvar]
        n = len(open(calls).read().splitlines())
        check(j.ok is False and n == want_calls, "%s=3 -> FAILED after %d PowerShell run(s) (got %d)" % (rcvar, want_calls, n))
        check(open(local, "rb").read() == mine, "%s failure: aliases.local.tsv still restored" % rcvar)
        check(any("Full log: " in l for l in j.lines), "%s failure: log path shown" % rcvar)
    # game running -> Install / update refused before build.ps1 (it would replace ps2run.exe); nothing changed, nothing stopped
    L.running_ps2run = lambda: [4321]; os.remove(calls); open(local, "wb").write(mine)
    try: j = run_job(L, lambda j: L.install(j, c))
    finally: L.running_ps2run = lambda: []
    check(j.ok is False and not os.path.exists(calls), "ps2run running -> install FAILED before any PowerShell run")
    check(any("already running (ps2run pid 4321)" in l for l in j.lines), "install shows the friendly game-running message")
    check(open(local, "rb").read() == mine, "ps2run running: aliases.local.tsv untouched")
    L.running_ps2run = lambda: None; open(local, "wb").write(mine)
    try: j = run_job(L, lambda j: L.install(j, c))
    finally: L.running_ps2run = lambda: []
    check(j.ok is False and not os.path.exists(calls) and any("Could not check" in l for l in j.lines), "tasklist failed -> install refused before any PowerShell run")
    c.set("paths", "iso", os.path.join(root, "missing.iso"))
    j = run_job(L, lambda j: L.install(j, c))
    check(j.ok is False and not os.path.exists(calls), "missing ISO -> FAILED before any PowerShell run")
    c.set("paths", "iso", iso)
finally:
    L.subprocess.Popen = real_popen

# 7) large speech model: same code as Linux, into <root>/vosk; the zip is closed before the .part is removed
zbuf = io.BytesIO()
with zipfile.ZipFile(zbuf, "w") as z:
    z.writestr(L.LARGE_MODEL + "/conf/model.conf", "x\n"); z.writestr(L.LARGE_MODEL + "/am/final.mdl", "y" * 1000)
zdata = zbuf.getvalue()
class Resp(io.BytesIO):
    headers = {"Content-Length": str(len(zdata))}
    def __enter__(self): return self
    def __exit__(self, *a): self.close()
L.urllib.request.urlopen = lambda url, timeout=0: Resp(zdata)
L.LARGE_MODEL_NEED_MB = 0
opened_zips = []
RealZip = zipfile.ZipFile
class TrackZip(RealZip):
    def __init__(self, *a, **k): super().__init__(*a, **k); opened_zips.append(self)
L.zipfile.ZipFile = TrackZip
real_remove = os.remove
def strict_remove(p):   # Windows refuses to delete a file that is still open
    if p.endswith(".zip.part") and any(z.fp is not None for z in opened_zips): raise PermissionError("still open: " + p)
    return real_remove(p)
L.os.remove = strict_remove
try:
    L.LARGE_MODEL_SHA = "0" * 64
    j = run_job(L, lambda j: L.download_large(j, c))
    check(j.ok is False and not os.path.exists(os.path.join(work, "vosk", L.LARGE_MODEL)), "sha mismatch -> discarded")
    L.LARGE_MODEL_SHA = hashlib.sha256(zdata).hexdigest()
    j = run_job(L, lambda j: L.download_large(j, c))
    d = os.path.join(work, "vosk")
    check(j.ok and os.path.isfile(os.path.join(d, L.LARGE_MODEL, "conf", "model.conf")), "large model unpacked to <root>/vosk: %s" % j.lines[-3:])
    check(sorted(os.listdir(d)) == [L.LARGE_MODEL], "no .zip.part / .unpack-* left: %r" % os.listdir(d))
    check(L.value_of(c, "large") == "installed", "menu shows the large model installed")
    j = run_job(L, lambda j: L.download_large(j, c)); check(j.ok and "Already downloaded." in j.lines, "second run: already downloaded")
finally:
    L.zipfile.ZipFile = RealZip; L.os.remove = real_remove

# 8) gamepad: SDL GameController events through pygame (dummy video); START plays run.ps1 via PowerShell, B quits.
#    Steam Big Picture on Windows (SteamTenfoot=1) opens the launcher fullscreen.
try:
    import pygame
except ImportError:
    pygame = None; print("skip: pygame not installed (gamepad checks)")
if pygame:
    os.environ["SDL_VIDEODRIVER"] = "dummy"; os.environ["SDL_AUDIODRIVER"] = "dummy"; os.environ["SteamTenfoot"] = "1"
    for k in ("SteamDeck", "XDG_CURRENT_DESKTOP", "GAMESCOPE_WAYLAND_DISPLAY"): os.environ.pop(k, None)
    sys.argv = ["x"]
    if os.path.exists(calls): os.remove(calls)
    open(os.path.join(work, "lifeline.env.json"), "w").write("{}")
    modes = []; real_set_mode = pygame.display.set_mode
    pygame.display.set_mode = lambda size, flags=0, *a, **k: (modes.append(flags), real_set_mode(size))[1]
    B = pygame.CONTROLLERBUTTONDOWN
    running = [[4321], []]   # 1st START: the game is still running -> refused; 2nd START: closed -> plays
    L.running_ps2run = lambda: running.pop(0) if running else []
    plan = [[pygame.event.Event(B, button=pygame.CONTROLLER_BUTTON_DPAD_DOWN)], [pygame.event.Event(B, button=pygame.CONTROLLER_BUTTON_DPAD_UP)],
            [pygame.event.Event(B, button=pygame.CONTROLLER_BUTTON_START)], "after-refused",
            [pygame.event.Event(B, button=pygame.CONTROLLER_BUTTON_START)], [], [pygame.event.Event(B, button=pygame.CONTROLLER_BUTTON_B)]]
    refused_state = []
    real_get = pygame.event.get
    def fake_get(*a, **k):
        real_get()
        if not plan: return [pygame.event.Event(pygame.QUIT)]
        p = plan.pop(0)
        if p == "after-refused":   # display still up and run.ps1 not started after the refused START
            refused_state.append((pygame.display.get_surface() is not None, os.path.exists(calls))); return []
        return p
    pygame.event.get = fake_get
    try: r = L.run_ui()
    finally: pygame.event.get = real_get; pygame.display.set_mode = real_set_mode; del os.environ["SteamTenfoot"]
    got = [json.loads(l) for l in open(calls)] if os.path.exists(calls) else []
    check(r == 0, "B quits the launcher")
    check(refused_state == [(True, False)], "START while ps2run runs: refused, menu stays, nothing started: %r" % refused_state)
    check(running == [], "game-running check made at each START")
    check(len(got) == 1 and got[0][2:5] == ["Bypass", "-File", os.path.join(work, "run.ps1")], "START ran run.ps1 through PowerShell once: %r" % got)
    check(modes and all(m & pygame.FULLSCREEN for m in modes), "SteamTenfoot=1 -> fullscreen launcher: %r" % modes)
    pygame.quit()

# 9) no POSIX-only calls in the launcher (the Linux-only lines are behind WIN or never reached on Windows)
BAD_ATTR = {"getuid", "geteuid", "getgid", "chmod", "chown", "symlink", "fork", "kill", "killpg", "setsid", "getpgid", "mkfifo", "uname"}
BAD_MOD = {"fcntl", "signal", "pwd", "grp", "termios", "resource", "pty"}
for fn in ("lifeline_launcher.py", "bindings.py"):
    tree = ast.parse(open(os.path.join(LAUNCHER, fn)).read())
    attrs = sorted({n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute) and n.attr in BAD_ATTR})
    mods = sorted({a.name.split(".")[0] for n in ast.walk(tree) if isinstance(n, (ast.Import, ast.ImportFrom))
                   for a in (n.names if isinstance(n, ast.Import) else [types.SimpleNamespace(name=n.module or "")]) if a.name.split(".")[0] in BAD_MOD})
    check(not attrs and not mods, "%s: no POSIX-only calls (%r %r)" % (fn, attrs, mods))
src = open(os.path.join(LAUNCHER, "lifeline_launcher.py")).read()
check(src.count('"/proc/cpuinfo"') == 1 and src.index("if WIN and not os.environ.get(\"LIFELINE_CPUINFO\"): return _win_cpu()") < src.index('"/proc/cpuinfo"'), "/proc/cpuinfo only after the Windows return")
check(src.index("if WIN: return install_win(") < src.index('"/run/.containerenv"'), "bash/distrobox install path only after the Windows return")

shutil.rmtree(root, ignore_errors=True)
print("%d FAILED" % fails if fails else "all windows tests passed"); sys.exit(1 if fails else 0)
