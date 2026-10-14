"""[qol] vu_fast: default off, available toggle saved to config.ini, run.sh passes PS2_VU_FAST=1 only when on,
an exported PS2_VU_FAST wins over config.ini, PS2_VU_CHECK passes through. Run: python3 test_vu_fast.py"""
import importlib, os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); LAUNCHER = os.path.dirname(HERE); KIT = os.path.dirname(LAUNCHER)
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)

root = tempfile.mkdtemp(); work = os.path.join(root, "work"); os.makedirs(work)
os.environ["LIFELINE_WORK"] = work; sys.path.insert(0, LAUNCHER)
L = importlib.import_module("lifeline_launcher"); sys.path.pop(0)
c = L.load()
check(c.get("qol", "vu_fast") == "0", "default off")
check(("qol:vu_fast", "9 Faster VU interpreter", True) in L.menu_items(c), "menu row present and available")
check(L.activate(c, "qol:vu_fast"), "toggle returns changed")
check(L.load().get("qol", "vu_fast") == "1", "toggle saved to config.ini")

# run.sh with a stub lifeline.env; LIFELINE_PRINT_ENV=1 prints what would be passed to ps2run
kit = os.path.join(root, "kit"); os.makedirs(kit); shutil.copy(os.path.join(KIT, "run.sh"), kit)
open(os.path.join(kit, "lifeline.env"), "w").write('VOSK_DIR=/x\nPS2_VOICE_VOSK_MODEL=/x/m\nPS2_VOICE_VOSK_LIB=/x/l\nPS2_VOICE_ASSETS=/x/a\n')
cfg = os.path.join(root, "config.ini")
def envs(vu_fast, extra=None):
    open(cfg, "w").write("[qol]\nvu_fast = %s\n" % vu_fast)
    e = {k: v for k, v in os.environ.items() if not k.startswith("PS2_")}
    e.update(LIFELINE_CONFIG=cfg, LIFELINE_PRINT_ENV="1", **(extra or {}))
    return subprocess.run(["bash", os.path.join(kit, "run.sh")], env=e, capture_output=True, text=True).stdout.split("\n")
check("PS2_VU_FAST=1" in envs("1"), "on -> PS2_VU_FAST=1")
check(not any(l.startswith("PS2_VU_FAST") for l in envs("0")), "off -> no PS2_VU_FAST (interpreter)")
check("PS2_VU_FAST=0" in envs("1", {"PS2_VU_FAST": "0"}), "exported PS2_VU_FAST=0 beats config.ini")
check("PS2_VU_CHECK=1" in envs("0", {"PS2_VU_CHECK": "1"}), "PS2_VU_CHECK passes through")
shutil.rmtree(root)
print("test_vu_fast: %s" % ("OK" if not fails else "%d FAILED" % fails)); sys.exit(1 if fails else 0)
