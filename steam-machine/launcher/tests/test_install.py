"""Install/update tests with a fake kit: runs install() from the INSTALLED launcher copy (as Steam does),
checks the install log, failure reporting, and atomic alias writes. Run: python3 test_install.py"""
import importlib, os, shutil, subprocess, sys, tempfile, threading, time
HERE = os.path.dirname(os.path.abspath(__file__)); LAUNCHER = os.path.dirname(HERE); REPO = os.path.dirname(os.path.dirname(LAUNCHER))
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)

def setup(build_rc=0, alias_rc=0):
    root = tempfile.mkdtemp(); work = os.path.join(root, "work"); kit = os.path.join(root, "kit", "steam-machine")
    os.makedirs(os.path.join(work, "launcher")); os.makedirs(os.path.join(work, "voice-assets"))
    os.makedirs(os.path.join(root, "kit", "voice", "tools")); shutil.copytree(LAUNCHER, os.path.join(kit, "launcher"), ignore=shutil.ignore_patterns("tests", "__pycache__"))
    for f in ("lifeline_launcher.py", "bindings.py", "launcher.sh"): shutil.copy2(os.path.join(LAUNCHER, f), os.path.join(work, "launcher", f))
    open(os.path.join(kit, "run.sh"), "w").write("#!/bin/sh\n# new run.sh\n")
    open(os.path.join(kit, "vu-check.sh"), "w").write("#!/bin/sh\n# new vu-check.sh\n"); os.chmod(os.path.join(kit, "vu-check.sh"), 0o755)
    open(os.path.join(kit, "build.sh"), "w").write('#!/bin/bash\necho "== step" >> "$2/build-progress.log"\necho "build stdout"\necho "build stderr" >&2\nexit %d\n' % build_rc)
    open(os.path.join(root, "kit", "voice", "tools", "build_aliases.py"), "w").write('import sys\nprint("alias stdout"); print("alias stderr", file=sys.stderr)\nsys.exit(%d)\n' % alias_rc)
    open(os.path.join(work, "voice-assets", "aliases.local.tsv"), "w").write("mine\n")
    iso = os.path.join(root, "disc.iso"); open(iso, "w").close()
    return root, work, kit, iso

def run_install(work, kit, iso):
    os.environ["LIFELINE_WORK"] = work
    sys.path.insert(0, os.path.join(work, "launcher"))   # the installed copy, like the Steam shortcut
    for m in ("lifeline_launcher", "bindings"): sys.modules.pop(m, None)
    L = importlib.import_module("lifeline_launcher"); sys.path.pop(0)
    check(L.HERE == os.path.join(work, "launcher"), "running from the installed copy")
    L.shutil.which = lambda n: None                      # no distrobox in tests
    L.running_ps2run = lambda: []                        # independent of games running on this machine
    c = L.load(); c.set("paths", "kit", kit); c.set("paths", "iso", iso)
    j = L.Job("Install / update", lambda j: L.install(j, c))
    while not j.done: time.sleep(0.05)
    return j

# 1) success from the installed copy (this used to fail with SameFileError)
root, work, kit, iso = setup()
j = run_install(work, kit, iso)
check(j.ok, "install from installed launcher succeeds: %s" % j.lines[-3:])
check(j.log_path and os.path.dirname(j.log_path) == os.path.join(work, "logs") and os.path.basename(j.log_path).startswith("install-"), "install log path")
log = open(j.log_path).read()
for s in ("build stdout", "build stderr", "alias stdout", "alias stderr", "exit 0", "== result: OK", "kit=", "cwd="):
    check(s in log, "install log has %r" % s)
check(open(os.path.join(work, "run.sh")).read().endswith("# new run.sh\n"), "run.sh installed")
vc = os.path.join(work, "vu-check.sh")
check(os.path.isfile(vc) and open(vc).read().endswith("# new vu-check.sh\n") and os.access(vc, os.X_OK), "vu-check.sh installed, executable")
check(not [f for f in os.listdir(os.path.join(work, "launcher")) if f.endswith(".tmp")], "no tmp files left")
check(open(os.path.join(work, "voice-assets", "aliases.local.tsv")).read() == "mine\n", "aliases.local.tsv untouched")
shutil.rmtree(root)

# 2) build failure: tail + exit code + path reported
root, work, kit, iso = setup(build_rc=3)
j = run_install(work, kit, iso)
check(not j.ok, "build failure reported")
check(any("failed (exit 3)" in l for l in j.lines) and any("build stderr" in l for l in j.lines), "tail with stderr on screen")
check(j.lines[-1] == "Full log: " + j.log_path, "log path shown last")
check("exit 3" in open(j.log_path).read() and "== result: FAILED" in open(j.log_path).read(), "exit code in log")
shutil.rmtree(root)

# 3) alias failure: still OK overall (game playable), exit code logged
root, work, kit, iso = setup(alias_rc=2)
j = run_install(work, kit, iso)
check(j.ok and "Aliases step failed" in "\n".join(j.lines) and "exit 2" in open(j.log_path).read(), "alias failure logged, install still OK")
shutil.rmtree(root)

# 4) build_aliases write_atomic: a failing write leaves the old file intact and no temp files
src = open(os.path.join(REPO, "voice", "tools", "build_aliases.py")).read()
ns = {}; exec(compile(src.split("def main():")[0], "build_aliases.py", "exec"), ns)
d = tempfile.mkdtemp(); p = os.path.join(d, "aliases.tsv"); open(p, "w").write("old\n")
ns["write_atomic"](p, "new\n"); check(open(p).read() == "new\n" and os.listdir(d) == ["aliases.tsv"], "atomic write replaces, no temp left")
real_fdopen = os.fdopen
class Half:
    def __init__(s, f): s.f = f
    def __enter__(s): return s
    def __exit__(s, *e): s.f.close()
    def write(s, t): s.f.write(t[:2]); raise IOError("disk full")
    def flush(s): pass
    def fileno(s): return s.f.fileno()
os.fdopen = lambda fd, *a, **k: Half(real_fdopen(fd, *a, **k))
try: ns["write_atomic"](p, "newer content\n"); check(False, "write error propagates")
except IOError: pass
finally: os.fdopen = real_fdopen
check(open(p).read() == "new\n", "failed write leaves the previous aliases.tsv intact")
check(os.listdir(d) == ["aliases.tsv"], "failed write cleans up its temp file")
shutil.rmtree(d)

# 5) launcher _write_atomic and _install_file clean up on failure; log names are unique
os.environ["LIFELINE_WORK"] = tempfile.mkdtemp(); sys.path.insert(0, LAUNCHER)
sys.modules.pop("lifeline_launcher", None); L = importlib.import_module("lifeline_launcher"); sys.path.pop(0)
d = tempfile.mkdtemp(); p = os.path.join(d, "f"); open(p, "wb").write(b"old")
os.fdopen = lambda fd, *a, **k: Half(real_fdopen(fd, *a, **k))
try: L._write_atomic(p, b"newer"); check(False, "_write_atomic error propagates")
except IOError: pass
finally: os.fdopen = real_fdopen
check(open(p, "rb").read() == b"old" and os.listdir(d) == ["f"], "_write_atomic failure keeps old file, no temp")
real_replace = L.os.replace
def bad_replace(a, b): raise OSError("rename failed")
L.os.replace = bad_replace
try: L._install_file(os.path.join(LAUNCHER, "bindings.py"), p); check(False, "_install_file error propagates")
except OSError: pass
finally: L.os.replace = real_replace
check(open(p, "rb").read() == b"old" and os.listdir(d) == ["f"], "_install_file failure keeps old file, no temp")
shutil.rmtree(d)
jobs = []
for _ in range(3):
    j = L.Job.__new__(L.Job); j.title, j.lock, j._f = "t", threading.Lock(), None; j.open_log("install"); jobs.append(j)
names = [j.log_path for j in jobs]
check(len(set(names)) == 3, "install log names unique: %s" % names)
for j in jobs: j._f.close()
shutil.rmtree(os.environ["LIFELINE_WORK"])
print("%d FAILED" % fails if fails else "all install tests passed"); sys.exit(1 if fails else 0)
