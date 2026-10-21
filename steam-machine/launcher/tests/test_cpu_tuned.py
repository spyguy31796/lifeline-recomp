"""[build] cpu_tuned: default off, toggle, rebuild-pending state, install passes CPU_TUNED and logs flags/flavor.
Run: python3 test_cpu_tuned.py"""
import importlib, os, shutil, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__)); LAUNCHER = os.path.dirname(HERE)
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)

def fresh(work):
    os.environ["LIFELINE_WORK"] = work; sys.path.insert(0, LAUNCHER)
    sys.modules.pop("lifeline_launcher", None); L = importlib.import_module("lifeline_launcher"); sys.path.pop(0)
    return L

root = tempfile.mkdtemp(); work = os.path.join(root, "work"); os.makedirs(work)
L = fresh(work); c = L.load()
check(c.get("build", "cpu_tuned") == "0", "default off")
check(("build:cpu_tuned", "CPU-tuned build (rebuild)", True) in L.menu_items(c), "menu has the build toggle, marked (rebuild)")
check(L.build_env(c)["CPU_TUNED"] == "0", "CPU_TUNED=0 by default")
check(not L.rebuild_pending(c), "nothing installed -> no rebuild pending")
open(os.path.join(work, "lifeline.env"), "w").write("x\n")           # installed, pre-option build (no build-flavor file)
check(not L.rebuild_pending(c), "old generic install, option off -> no rebuild")
check(L.activate(c, "build:cpu_tuned"), "toggle returns changed")
check(L.load().get("build", "cpu_tuned") == "1", "toggle saved to config.ini")
check(L.rebuild_pending(c) and L.value_of(c, "build:cpu_tuned") == "ON (rebuild)", "toggled on -> rebuild pending shown")
check(L.build_env(c)["CPU_TUNED"] == "1", "CPU_TUNED=1 when on")
open(os.path.join(work, "build-flavor"), "w").write("cpu_tuned\n")
check(not L.rebuild_pending(c) and L.value_of(c, "build:cpu_tuned") == "ON", "tuned build installed -> not pending")
open(os.path.join(work, "build-flavor"), "w").write("generic-fallback\n")
check(L.rebuild_pending(c) and "rebuild" in L.value_of(c, "build:cpu_tuned"), "fallback while on -> still pending (retry on next install)")
L.activate(c, "build:cpu_tuned")
check(not L.rebuild_pending(c), "fallback build counts as generic when off")
# CPU model in build-flavor: a tuned build from another CPU asks for a rebuild
L.activate(c, "build:cpu_tuned")   # on again
cpuinfo = os.path.join(root, "cpuinfo"); open(cpuinfo, "w").write("processor\t: 0\nmodel name\t: CPU A\n")
os.environ["LIFELINE_CPUINFO"] = cpuinfo
open(os.path.join(work, "build-flavor"), "w").write("cpu_tuned\ncpu=CPU A\n")
check(L.built_flavor() == "cpu_tuned" and L.built_cpu() == "CPU A" and L.current_cpu() == "CPU A", "flavor + cpu read")
check(not L.cpu_changed() and not L.rebuild_pending(c) and L.value_of(c, "build:cpu_tuned") == "ON", "same CPU: nothing pending")
open(cpuinfo, "w").write("model name\t: CPU B\n")
check(L.cpu_changed() and L.rebuild_pending(c), "other CPU: rebuild pending")
check(L.value_of(c, "build:cpu_tuned") == "ON (rebuild: new CPU)" and "CPU A -> CPU B" in L.cpu_change_msg(), "prompt names both CPUs")
open(os.path.join(work, "build-flavor"), "w").write("cpu_tuned\n")
check(not L.cpu_changed(), "older build-flavor without cpu= line: no prompt")
open(os.path.join(work, "build-flavor"), "w").write("generic\ncpu=CPU A\n"); L.activate(c, "build:cpu_tuned")
check(not L.cpu_changed() and not L.rebuild_pending(c), "generic builds run anywhere: no prompt")
del os.environ["LIFELINE_CPUINFO"]
check(L.main(["--set", "build.cpu_tuned=1"]) == 0 and L.load().get("build", "cpu_tuned") == "1", "--set build.cpu_tuned works")

# install passes CPU_TUNED to build.sh and logs flags + built flavor
kit = os.path.join(root, "kit", "steam-machine"); os.makedirs(os.path.join(root, "kit", "voice", "tools")); os.makedirs(kit)
shutil.copytree(LAUNCHER, os.path.join(kit, "launcher"), ignore=shutil.ignore_patterns("tests", "__pycache__"))
open(os.path.join(kit, "run.sh"), "w").write("#!/bin/sh\n")
open(os.path.join(kit, "build.sh"), "w").write('#!/bin/bash\necho "build sees CPU_TUNED=$CPU_TUNED"\n'
    '[ "$CPU_TUNED" = 1 ] && echo cpu_tuned > "$2/build-flavor" || echo generic > "$2/build-flavor"\n')
open(os.path.join(root, "kit", "voice", "tools", "build_aliases.py"), "w").write("pass\n")
iso = os.path.join(root, "disc.iso"); open(iso, "w").close()
for on in ("1", "0"):
    L = fresh(work); L.shutil.which = lambda n: None; L.running_ps2run = lambda: []   # independent of games running here
    c = L.load(); c.set("paths", "kit", kit); c.set("paths", "iso", iso); c.set("build", "cpu_tuned", on)
    j = L.Job("Install / update", lambda j: L.install(j, c))
    while not j.done: time.sleep(0.05)
    log = open(j.log_path).read()
    check(j.ok, "install ok (cpu_tuned=%s)" % on)
    check("Build options: cpu_tuned=%s (CPU_TUNED=%s" % (on, on) in log, "flags logged in install log (%s)" % on)
    check(("-march=native -flto=thin" in log) == (on == "1"), "tuned flags named only when on (%s)" % on)
    check("build sees CPU_TUNED=%s" % on in log, "build.sh got CPU_TUNED=%s" % on)
    check("Built flavor: %s" % ("cpu_tuned" if on == "1" else "generic") in log, "built flavor logged (%s)" % on)
    check(not L.rebuild_pending(c), "after install nothing pending (%s)" % on)
shutil.rmtree(root)
print("%d FAILED" % fails if fails else "all cpu_tuned tests passed"); sys.exit(1 if fails else 0)
