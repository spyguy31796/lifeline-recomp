"""Game-running check (Linux): PLAY / New game / Install refuse while a ps2run process exists, with a friendly
message; the check only reads the process list (pgrep -x ps2run) and never stops anything. Also: the installed
launcher gets the pinned launcher-requirements.txt, and launcher.sh pip-installs from it. Run: python3 test_game_running.py"""
import os, shutil, subprocess, sys, tempfile, time
os.environ["SDL_VIDEODRIVER"] = "dummy"; os.environ["SDL_AUDIODRIVER"] = "dummy"
HERE = os.path.dirname(os.path.abspath(__file__)); LAUNCHER = os.path.dirname(HERE); REPO = os.path.dirname(os.path.dirname(LAUNCHER))
work = tempfile.mkdtemp(); os.environ["LIFELINE_WORK"] = work
sys.argv = ["x"]; sys.path.insert(0, LAUNCHER)
import lifeline_launcher as L
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)

# 1) running_ps2run: pgrep -x ps2run, parsed; pgrep missing -> []; nothing but pgrep is run
ran = []
class R:
    def __init__(self, out): self.stdout, self.returncode = out, 0 if out else 1
real_run = L.subprocess.run
try:
    L.subprocess.run = lambda cmd, **k: (ran.append(list(cmd)), R("4321\n77\n"))[1]
    check(L.running_ps2run() == [4321, 77], "pgrep output -> pids")
    L.subprocess.run = lambda cmd, **k: (ran.append(list(cmd)), R(""))[1]
    check(L.running_ps2run() == [], "no match -> []")
    L.subprocess.run = lambda cmd, **k: (_ for _ in ()).throw(FileNotFoundError("pgrep"))
    check(L.running_ps2run() == [], "pgrep missing -> []")
    check(ran and all(c == ["pgrep", "-x", "ps2run"] for c in ran), "only 'pgrep -x ps2run' is run: %r" % ran)
finally:
    L.subprocess.run = real_run
check(L.game_running_msg([4321]) == "The game is already running (ps2run pid 4321): close it first", "message text")
# a real (stand-in) process named ps2run is found and left running; we stop our own stand-in by its PID afterwards
if shutil.which("pgrep"):
    d = tempfile.mkdtemp(); exe = os.path.join(d, "ps2run"); shutil.copy("/bin/sleep", exe)
    p = subprocess.Popen([exe, "30"])
    try:
        time.sleep(0.3)
        got = L.running_ps2run()
        check(p.pid in got, "stand-in ps2run (pid %d) found: %r" % (p.pid, got))
        check(p.poll() is None, "the running ps2run was not touched")
    finally:
        if p.poll() is None: p.terminate(); p.wait()   # our own stand-in only, by its PID
        shutil.rmtree(d, ignore_errors=True)

# 2) Install / update refused before build.sh while the game runs; aliases.local.tsv untouched
kit = os.path.join(work, "kit", "steam-machine"); os.makedirs(kit)
open(os.path.join(kit, "build.sh"), "w").write("#!/bin/sh\necho ran > \"$2/build-ran\"\n")
iso = os.path.join(work, "disc.iso"); open(iso, "w").close()
local = os.path.join(work, "voice-assets", "aliases.local.tsv"); os.makedirs(os.path.dirname(local)); open(local, "wb").write(b"mine\r\n")
c = L.load(); c.set("paths", "kit", kit); c.set("paths", "iso", iso)
L.running_ps2run = lambda: [4321]
j = L.Job("Install / update", lambda j: L.install(j, c))
while not j.done: time.sleep(0.02)
check(j.ok is False and not os.path.exists(os.path.join(work, "build-ran")), "install refused, build.sh not run")
check(any("already running (ps2run pid 4321)" in l and "nothing was changed" in l for l in j.lines), "install shows the message: %r" % j.lines)
check(open(local, "rb").read() == b"mine\r\n", "aliases.local.tsv untouched")

# 3) the installed launcher gets launcher-requirements.txt from the kit's windows/ folder
req = os.path.join(REPO, "windows", "launcher-requirements.txt")
check(os.path.isfile(req) and "pygame-ce==2.5.8" in open(req).read() and open(req).read().count("--hash=sha256:") == 12, "shared requirements file pins pygame-ce 2.5.8 with 12 hashes")
fk = os.path.join(work, "fk"); os.makedirs(os.path.join(fk, "windows")); shutil.copytree(LAUNCHER, os.path.join(fk, "steam-machine", "launcher"), ignore=shutil.ignore_patterns("tests", "__pycache__"))
shutil.copy2(req, os.path.join(fk, "windows")); open(os.path.join(fk, "steam-machine", "run.sh"), "w").write("#!/bin/sh\n")
open(os.path.join(fk, "steam-machine", "build.sh"), "w").write("#!/bin/sh\nexit 0\n"); os.makedirs(os.path.join(fk, "voice", "tools"))
open(os.path.join(fk, "voice", "tools", "build_aliases.py"), "w").write("")
L.running_ps2run = lambda: []; L.shutil.which = lambda n: None
c.set("paths", "kit", os.path.join(fk, "steam-machine"))
j = L.Job("Install / update", lambda j: L.install(j, c))
while not j.done: time.sleep(0.02)
inst = os.path.join(work, "launcher", "launcher-requirements.txt")
check(j.ok and os.path.isfile(inst) and open(inst, "rb").read() == open(req, "rb").read(), "launcher-requirements.txt installed next to launcher.sh: %r" % j.lines[-3:])

# 4) PLAY refused while the game runs (menu stays, run.sh not started); runs once the game is closed
try:
    import pygame
except ImportError:
    pygame = None; print("skip: pygame not installed (PLAY check)")
if pygame:
    open(os.path.join(work, "lifeline.env"), "w").close(); runs = os.path.join(work, "runs")
    open(os.path.join(work, "run.sh"), "w").write('#!/bin/sh\necho x >> "%s"\n' % runs); os.chmod(os.path.join(work, "run.sh"), 0o755)
    states = [[4321], []]; L.running_ps2run = lambda: states.pop(0) if states else []
    B = pygame.CONTROLLERBUTTONDOWN; seen = []
    plan = [[pygame.event.Event(B, button=pygame.CONTROLLER_BUTTON_START)], "check", [pygame.event.Event(B, button=pygame.CONTROLLER_BUTTON_START)], [],
            [pygame.event.Event(B, button=pygame.CONTROLLER_BUTTON_B)]]
    real = pygame.event.get
    def fake(*a, **k):
        real()
        if not plan: return [pygame.event.Event(pygame.QUIT)]
        p = plan.pop(0)
        if p == "check": seen.append((pygame.display.get_surface() is not None, os.path.exists(runs))); return []
        return p
    pygame.event.get = fake
    try: r = L.run_ui()
    finally: pygame.event.get = real
    check(seen == [(True, False)], "START while ps2run runs: refused, menu stays, nothing started: %r" % seen)
    check(os.path.exists(runs) and open(runs).read().count("x") == 1, "START after the game closed runs run.sh once")
    check(r == 0 and states == [], "checked at each START; B quits")

shutil.rmtree(work, ignore_errors=True)
print("%d FAILED" % fails if fails else "all game-running tests passed"); sys.exit(1 if fails else 0)
