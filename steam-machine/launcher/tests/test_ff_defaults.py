"""Fresh config: fast_forward (item 11) is off; faster_loads stays the reserved item 8. Run: python3 test_ff_defaults.py"""
import os, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.dirname(HERE))
os.environ["LIFELINE_WORK"] = tempfile.mkdtemp()
import lifeline_launcher as L
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)
c = L.load()
check(c.get("qol", "fast_forward") == "0", "fast_forward default is %s" % c.get("qol", "fast_forward"))
check(L.DEFAULTS["qol"]["fast_forward"] == "0", "DEFAULTS fast_forward on")
items = {q[0]: q for q in L.QOL}
check(items["faster_loads"][3] is False, "faster_loads (reserved) is not available")
check(items["fast_forward"][2] == "bool", "fast_forward is a toggle")
print("ff defaults tests passed" if not fails else "ff defaults tests FAILED"); sys.exit(1 if fails else 0)
