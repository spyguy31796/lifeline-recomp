"""PLAY waits for run.sh and returns to the menu when the game exits (0 from the quit hotkey, or an error).
Dummy video, stub run.sh. Run: python3 test_play.py"""
import os, sys, tempfile
os.environ["SDL_VIDEODRIVER"] = "dummy"; os.environ["SDL_AUDIODRIVER"] = "dummy"
work = tempfile.mkdtemp(); os.environ["LIFELINE_WORK"] = work
open(os.path.join(work, "lifeline.env"), "w").close()
runs = os.path.join(work, "runs")
with open(os.path.join(work, "run.sh"), "w") as f:   # 1st run exits 0 (hotkey quit), 2nd exits 3
    f.write('#!/bin/sh\necho x >> "%s"\n[ "$(wc -l < "%s")" -ge 2 ] && exit 3\nexit 0\n' % (runs, runs))
os.chmod(os.path.join(work, "run.sh"), 0o755)
sys.argv = ["x"]; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pygame, lifeline_launcher as L
fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)
start = lambda: [pygame.event.Event(pygame.CONTROLLERBUTTONDOWN, button=pygame.CONTROLLER_BUTTON_START)]
seen = []
plan = [start, "menu", start, "menu", lambda: [pygame.event.Event(pygame.CONTROLLERBUTTONDOWN, button=pygame.CONTROLLER_BUTTON_B)]]
real = pygame.event.get
def fake(*a, **k):
    real()
    if not plan: return [pygame.event.Event(pygame.QUIT)]
    p = plan.pop(0)
    if p == "menu": seen.append(pygame.display.get_init() and pygame.display.get_surface() is not None); return []
    return p()
pygame.event.get = fake
r = L.run_ui()
check(r == 0, "launcher exits 0 on B")
check(open(runs).read().count("x") == 2, "game launched twice (menu came back after exit 0)")
check(seen == [True, True], "menu re-shown after each game exit: %r" % seen)
print("%d FAILED" % fails if fails else "all play tests passed"); sys.exit(1 if fails else 0)
