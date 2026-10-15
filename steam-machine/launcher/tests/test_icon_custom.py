"""[qol] button_icons keeps a custom icons.local pack: a hand-set value survives saves from other toggles,
cycling includes it and user packs in icons.local/, and the menu shows it. Run: python3 test_icon_custom.py"""
import importlib, os, shutil, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); LAUNCHER = os.path.dirname(HERE)
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)

work = tempfile.mkdtemp(); os.environ["LIFELINE_WORK"] = work; sys.path.insert(0, LAUNCHER)
L = importlib.import_module("lifeline_launcher"); sys.path.pop(0)
os.makedirs(os.path.join(work, "icons.local", "mypack")); open(os.path.join(work, "icons.local", "mypack", "icons.txt"), "w").close()
os.makedirs(os.path.join(work, "icons", "handset")); open(os.path.join(work, "icons", "handset", "icons.txt"), "w").close()
os.makedirs(os.path.join(work, "icons.local", "nomanifest"))   # no icons.txt: not offered
c = L.load(); L.save(c)
cfg = open(L.CFG).read().replace("button_icons = ps2", "button_icons = handset")   # edited by hand
open(L.CFG, "w").write(cfg)

c = L.load()
check(c.get("qol", "button_icons") == "handset", "hand-set value loaded")
check(L.value_of(c, "qol:button_icons") == "handset", "menu shows the pack name (no 'x' suffix): %r" % L.value_of(c, "qol:button_icons"))
check(L.value_of(c, "qol:resolution_scale") == "1x", "resolution keeps its 'x' suffix")
L.activate(c, "qol:widescreen")                       # saving another toggle
check(L.load().get("qol", "button_icons") == "handset", "custom value kept when another toggle is saved")
vals = L.choices(c, "button_icons")
check(vals[:3] == ["ps2", "xbox", "deck"] and "mypack" in vals and "handset" in vals and "nomanifest" not in vals, "choices: %r" % vals)
seen = set()
for _ in range(len(vals)):
    L.activate(c, "qol:button_icons"); seen.add(L.load().get("qol", "button_icons"))
check(seen == set(vals), "cycling visits every pack and comes back: %r" % sorted(seen))
check(L.load().get("qol", "button_icons") == "handset", "full cycle returns to the custom value")
c.set("qol", "button_icons", "gone")        # hand-set, no pack on disk: kept until cycled away
check(L.choices(c, "button_icons")[-1] == "gone", "hand-set value without a pack is still offered")
c.set("qol", "button_icons", "bad/name")
check("bad/name" not in L.choices(c, "button_icons"), "names run.sh would reject are not offered")
shutil.rmtree(work)
print("test_icon_custom: %s" % ("OK" if not fails else "%d FAILED" % fails)); sys.exit(1 if fails else 0)
