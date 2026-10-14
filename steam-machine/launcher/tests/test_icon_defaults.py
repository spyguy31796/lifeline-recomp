"""Fresh config: button_icons defaults to ps2 (original glyphs, texture hook off). Run: python3 test_icon_defaults.py"""
import os, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.dirname(HERE))
os.environ["LIFELINE_WORK"] = tempfile.mkdtemp()
import lifeline_launcher as L
fails = 0
c = L.load()
if c.get("qol", "button_icons") != "ps2": fails += 1; print("FAIL: button_icons default is", c.get("qol", "button_icons"))
if L.DEFAULTS["qol"]["button_icons"] != "ps2": fails += 1; print("FAIL: DEFAULTS button_icons")
choices = [q[2][1] for q in L.QOL if q[0] == "button_icons"][0]
if choices[0] != "ps2": fails += 1; print("FAIL: ps2 is not the first choice")
print("icon defaults tests passed" if not fails else "icon defaults tests FAILED"); sys.exit(1 if fails else 0)
