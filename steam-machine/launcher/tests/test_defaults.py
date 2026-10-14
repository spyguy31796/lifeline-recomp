"""Fresh config defaults: save_slots must be off until the user turns it on. Run: python3 test_defaults.py"""
import os, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.dirname(HERE))
os.environ["LIFELINE_WORK"] = tempfile.mkdtemp()
import lifeline_launcher as L
c = L.load()
fails = 0
if c.get("qol", "save_slots") != "0": fails += 1; print("FAIL: save_slots default is", c.get("qol", "save_slots"))
if L.DEFAULTS["qol"]["save_slots"] != "0": fails += 1; print("FAIL: DEFAULTS save_slots on")
print("defaults tests passed" if not fails else "defaults tests FAILED"); sys.exit(1 if fails else 0)
