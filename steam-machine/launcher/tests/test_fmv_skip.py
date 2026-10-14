"""[qol] fmv_skip (item 12): launcher defaults (every QoL toggle off; resolution_scale 1, button_icons ps2), menu row and order,
item 8 label no longer promises FMV skip, toggle saved; run.sh passes PS2_FMV_SKIP=1 only when on, an exported
PS2_FMV_SKIP (including empty) wins over config.ini. Run: python3 test_fmv_skip.py"""
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
# defaults: a fresh config has every QoL toggle off (choices: resolution_scale 1, button_icons ps2)
for k, *_ in L.QOL:
    check(c.get("qol", k) == {"resolution_scale": "1", "button_icons": "ps2"}.get(k, "0"), "default for %s" % k)
check(c.get("qol", "fmv_skip") == "0", "fmv_skip default off")
items = L.menu_items(c)
check(("qol:fmv_skip", "12 Skip movies", True) in items, "menu row 12 present and available")
keys = [k for k, *_ in items]
check(keys.index("qol:fmv_skip") == keys.index("qol:fast_forward") + 1, "item 12 comes right after item 11 (fast-forward)")
lbl8 = next(lbl for k, lbl, *_ in items if k == "qol:faster_loads")
check("FMV" not in lbl8.upper() and "SKIP" not in lbl8.upper(), "item 8 label does not promise FMV skip: %r" % lbl8)
hint = next(q[4] for q in L.QOL if q[0] == "fmv_skip")
check("Start" in hint and "Cross" not in hint, "hint says Start only")
check(L.activate(c, "qol:fmv_skip"), "toggle returns changed")
check(L.load().get("qol", "fmv_skip") == "1", "toggle saved to config.ini")

kit = os.path.join(root, "kit"); os.makedirs(kit); shutil.copy(os.path.join(KIT, "run.sh"), kit)
open(os.path.join(kit, "lifeline.env"), "w").write('VOSK_DIR=/x\nPS2_VOICE_VOSK_MODEL=/x/m\nPS2_VOICE_VOSK_LIB=/x/l\nPS2_VOICE_ASSETS=/x/a\n')
cfg = os.path.join(root, "config.ini")
def envs(on, extra=None):
    open(cfg, "w").write("[qol]\nfmv_skip = %s\n" % on)
    e = {k: v for k, v in os.environ.items() if not k.startswith("PS2_")}
    e.update(LIFELINE_CONFIG=cfg, LIFELINE_PRINT_ENV="1", **(extra or {}))
    return subprocess.run(["bash", os.path.join(kit, "run.sh")], env=e, capture_output=True, text=True).stdout.split("\n")
check("PS2_FMV_SKIP=1" in envs("1"), "on -> PS2_FMV_SKIP=1")
check(not any(l.startswith("PS2_FMV_SKIP") for l in envs("0")), "off -> no PS2_FMV_SKIP")
check("PS2_FMV_SKIP=0" in envs("1", {"PS2_FMV_SKIP": "0"}), "exported PS2_FMV_SKIP=0 beats config.ini")
check("PS2_FMV_SKIP=" in envs("1", {"PS2_FMV_SKIP": ""}), "exported empty PS2_FMV_SKIP passes through (off) despite fmv_skip=1")
check(not any(l == "PS2_FMV_SKIP=1" for l in envs("1", {"PS2_FMV_SKIP": ""})), "empty env never becomes 1")
check(sum(l.startswith("PS2_FMV_SKIP=") for l in envs("1")) == 1, "passed exactly once")
shutil.rmtree(root)
print("test_fmv_skip: %s" % ("OK" if not fails else "%d FAILED" % fails)); sys.exit(1 if fails else 0)
