"""launcher.sh first run: creates the venv and pip-installs pygame-ce from the pinned launcher-requirements.txt
(installed copy: next to launcher.sh; repo: windows/), with --only-binary. Stub python3 on PATH, no network.
Run: python3 test_launcher_sh.py"""
import json, os, shutil, stat, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); LAUNCHER = os.path.dirname(HERE); REPO = os.path.dirname(os.path.dirname(LAUNCHER))
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)
STUB = r'''#!/bin/sh
# stand-in python3: records its arguments; "import pygame" works only after a pip install into this interpreter
LOG=%(log)s; D=$(dirname "$0")
printf '%%s\n' "$0 $*" >> "$LOG"
case "$1 $2" in
  "-c import pygame") [ -f "$D/.has_pygame" ] && exit 0; exit 1;;
  "-m venv") mkdir -p "$3/bin"; cp "$0" "$3/bin/python"; exit 0;;
  "-m pip") touch "$D/.has_pygame"; exit 0;;
esac
exit 0
'''
def run(launcher_dir):
    t = tempfile.mkdtemp(); bindir = os.path.join(t, "bin"); os.makedirs(bindir); log = os.path.join(t, "calls")
    py = os.path.join(bindir, "python3"); open(py, "w").write(STUB % {"log": log}); os.chmod(py, 0o755)
    env = dict(os.environ, PATH=bindir + ":/usr/bin:/bin", LIFELINE_WORK=os.path.join(t, "work"), HOME=t)
    r = subprocess.run(["bash", os.path.join(launcher_dir, "launcher.sh"), "--dry-run"], env=env, capture_output=True, text=True)
    calls = open(log).read().splitlines() if os.path.exists(log) else []
    shutil.rmtree(t, ignore_errors=True)
    return r, calls
req_repo = os.path.realpath(os.path.join(REPO, "windows", "launcher-requirements.txt"))
# from the repo: windows/launcher-requirements.txt
r, calls = run(LAUNCHER)
pip = [c for c in calls if " -m pip " in c]
check(r.returncode == 0, "launcher.sh exit 0: %s" % r.stderr)
check(len(pip) == 1 and "--only-binary=:all: -r " in pip[0] and os.path.realpath(pip[0].split(" -r ")[1].strip()) == req_repo, "repo: pip -r windows/launcher-requirements.txt: %r" % pip)
check(any(c.endswith("lifeline_launcher.py --dry-run") for c in calls), "then runs lifeline_launcher.py with the venv python")
# installed copy: launcher-requirements.txt next to launcher.sh
inst = tempfile.mkdtemp()
for f in ("launcher.sh", "lifeline_launcher.py", "bindings.py"): shutil.copy2(os.path.join(LAUNCHER, f), inst)
shutil.copy2(req_repo, os.path.join(inst, "launcher-requirements.txt"))
r, calls = run(inst); pip = [c for c in calls if " -m pip " in c]
check(len(pip) == 1 and pip[0].split(" -r ")[1].strip() == os.path.join(inst, "launcher-requirements.txt"), "installed: pip -r <launcher>/launcher-requirements.txt: %r" % pip)
# an old install without the file: still pinned (pygame-ce==2.5.8)
os.remove(os.path.join(inst, "launcher-requirements.txt"))
r, calls = run(inst); pip = [c for c in calls if " -m pip " in c]
check(len(pip) == 1 and pip[0].endswith("--only-binary=:all: pygame-ce==2.5.8"), "no requirements file: pygame-ce==2.5.8: %r" % pip)
shutil.rmtree(inst, ignore_errors=True)
print("%d FAILED" % fails if fails else "all launcher.sh tests passed"); sys.exit(1 if fails else 0)
