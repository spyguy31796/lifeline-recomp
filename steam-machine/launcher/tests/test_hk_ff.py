"""hk_ff (fast-forward, held) is a launcher hotkey: listed, default matches ourcode/input/input_map.cpp, valid,
no Circle, rebindable, and in the PS2_INPUT_MAP string (to_env, used by --dry-run). Run: python3 test_hk_ff.py"""
import configparser, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.dirname(HERE))
import bindings as B
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)

keys = [k for k, _ in B.HOTKEYS]
check("hk_ff" in keys, "hk_ff listed in HOTKEYS")
src = open(os.path.join(HERE, "..", "..", "..", "input", "input_map.cpp")).read()
names = re.search(r'kHotkeyNames\[kHotkeyCount\] = \{([^}]*)\}', src).group(1)
defs = re.findall(r'^\s*"([^"]*)",', re.search(r'kHotkeyDefaults\[kHotkeyCount\] = \{(.*?)\};', src, re.S).group(1), re.M)
cpp = dict(zip(re.findall(r'"(hk_[a-z]+)"', names), defs))
check(set(cpp) == set(keys), "launcher hotkeys match input_map.cpp: %s vs %s" % (sorted(keys), sorted(cpp)))
for k in keys: check(B.HOTKEY_DEFAULTS.get(k) == cpp.get(k), "%s default matches input_map.cpp" % k)
check(B.validate("hk_ff", B.HOTKEY_DEFAULTS["hk_ff"]) == "", "default is valid")
check(B.push_to_talk_warning(configparser.ConfigParser(), "hk_ff") == "", "default has no Circle")
check(B.push_to_talk_warning(configparser.ConfigParser(), "hk_ff", "b") != "", "binding Circle's source warns")

cfg = configparser.ConfigParser()
B.set_binding(cfg, "hk_ff", "key:F7, back&leftshoulder")
env = B.to_env(cfg)
check(";hk_ff=key:F7, back&leftshoulder" in env, "rebound hk_ff in PS2_INPUT_MAP: " + env[-60:])
cfg2 = configparser.ConfigParser(); B.set_binding(cfg2, "cross", "a")
check(";hk_ff=%s" % B.HOTKEY_DEFAULTS["hk_ff"] in B.to_env(cfg2), "first edit writes the hk_ff default too")
print("test_hk_ff: %s" % ("OK" if not fails else "%d FAILED" % fails)); sys.exit(1 if fails else 0)
