"""Tests for the launcher's bindings: state machine, config/env round trip, and a scripted
controller run of the bindings screen (dummy video). Run: python3 test_bindings.py"""
import configparser, os, sys
os.environ.setdefault("SDL_VIDEODRIVER", "dummy"); os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import bindings as B

fails = 0
def check(c, what):
    global fails
    if not c: fails += 1; print("FAIL:", what)

# --- Capture state machine (times passed explicitly) ---
c = B.Capture(now=0); c.feed("a", False, now=0.0)              # the A that opened capture is released
check(c.tick(0.1) is None and c.phase == "settle", "settles first")
check(c.tick(0.3) is None and c.phase == "wait", "listening after settle")
c.feed("paddle1", True, now=1.0); check(c.feed("paddle1", False, now=1.2) == ("bind", "paddle1"), "press+release binds")
c = B.Capture(now=0); c.feed("a", True, now=0)                 # still holding A: no listening yet
check(c.tick(5) is None and c.phase == "settle", "held nav button is never bound")
c.feed("a", False, now=5); c.tick(5.3); c.feed("b", True, now=6); check(c.tick(6 + B.HOLD_CANCEL) == ("cancel", "held to cancel"), "hold cancels")
c = B.Capture(now=0); c.tick(0.3); check(c.tick(0.3 + B.TIMEOUT) == ("cancel", "timed out"), "timeout cancels")
c = B.Capture(now=0); c.tick(0.3); c.feed("b", True, 1); check(c.feed("x", False, 1.1) is None, "other release ignored")

# --- config <-> env ---
cfg = configparser.ConfigParser()
check(B.to_env(cfg) == "" and B.current(cfg, "circle") == "b", "no section = defaults, no env")
B.set_binding(cfg, "circle", "paddle1"); B.add_binding(cfg, "circle", "b"); B.add_binding(cfg, "circle", "b")
check(cfg.get("bindings", "circle") == "paddle1, b", "add dedups")
check(cfg.get("bindings", "cross") == "a" and len(cfg.options("bindings")) == 20, "full layout written on first edit")
env = B.to_env(cfg); check(env.startswith("circle=paddle1, b;cross=a;") and "lx=leftx" in env, "env string")
check(B.pretty("-lefty, righty~, paddle1") == "LS Y-, RS Y inverted, Paddle 1", "pretty")
B.reset(cfg); check(not cfg.has_section("bindings"), "reset")

# --- nits: inline comments, forbidden keys, --set validation ---
cfg = configparser.ConfigParser(inline_comment_prefixes=("#", ";"))
cfg.read_string("[bindings]\ncircle = b, paddle1   # push-to-talk\nup = dpup ; note\n")
check(B.current(cfg, "circle") == "b, paddle1" and B.current(cfg, "up") == "dpup", "configparser strips inline comments")
raw = configparser.ConfigParser(); raw.read_string("[bindings]\ncircle = b, paddle1   # push-to-talk\n")
check(B.current(raw, "circle") == "b, paddle1", "current() strips comments even without inline prefixes")
check("circle=b, paddle1" in B.to_env(raw), "to_env has no comment")
for good in [("circle", "b, paddle1"), ("up", "-lefty"), ("lx", "rightx~"), ("ly", "joy:a1"), ("r2", "joy:a5+, righttrigger"),
             ("down", "joy:h0.down"), ("square", "key:space"), ("select", "none"), ("start", "start # x")]:
    check(B.validate(*good) == "", "valid %r: %s" % (good, B.validate(*good)))
for bad in [("circle", "zz"), ("bogus", "a"), ("lx", "a"), ("lx", "+leftx"), ("up", "+a"), ("up", "lefty~"),
            ("r1", "joy:b256"), ("r1", "joy:b-1"), ("square", "key:,"), ("square", "key:;"), ("square", "key:="), ("square", "key:")]:
    check(B.validate(*bad) != "", "invalid %r accepted" % (bad,))
import pygame as pg
pg.init()
for ch in (",", ";", "="):
    e = pg.event.Event(pg.KEYDOWN, key=ord(ch))
    check(B.event_inputs(pg, e, False, set()) == [], "key %r rejected by capture" % ch)
check(B.event_inputs(pg, pg.event.Event(pg.KEYDOWN, key=pg.K_SPACE), False, set()) == [("key:space", True)], "space capturable")

# --- scripted controller run of the screen ---
import pygame as pg
pg.init(); scr = pg.display.set_mode((1280, 800)); f = pg.font.Font(None, 30)
cfg = configparser.ConfigParser(); saved = []
def btn(b, down=True): return pg.event.Event(pg.CONTROLLERBUTTONDOWN if down else pg.CONTROLLERBUTTONUP, button=b)
def axis(a, v): return pg.event.Event(pg.CONTROLLERAXISMOTION, axis=a, value=v)
import time
B.SETTLE, B.HOLD_CANCEL, B.TIMEOUT = 0.05, 0.3, 0.6
plan = [
    [btn(pg.CONTROLLER_BUTTON_A)], [btn(pg.CONTROLLER_BUTTON_A, False)], "wait",     # rebind Circle (row 0)
    [btn(16)], [btn(16, False)], "wait",                                             # paddle1 -> bound
    [btn(pg.CONTROLLER_BUTTON_Y)], [btn(pg.CONTROLLER_BUTTON_Y, False)], "wait",     # add another
    [btn(pg.CONTROLLER_BUTTON_B)], [btn(pg.CONTROLLER_BUTTON_B, False)], "wait",     # B is bindable during capture
    [btn(pg.CONTROLLER_BUTTON_DPAD_DOWN)], [btn(pg.CONTROLLER_BUTTON_A)], [btn(pg.CONTROLLER_BUTTON_A, False)], "wait",  # Cross
    [btn(pg.CONTROLLER_BUTTON_X)], "long", [btn(pg.CONTROLLER_BUTTON_X, False)], "wait",  # hold X -> cancel
    [btn(pg.CONTROLLER_BUTTON_DPAD_DOWN)], [btn(pg.CONTROLLER_BUTTON_A)], [btn(pg.CONTROLLER_BUTTON_A, False)], "wait",  # Square
    "timeout",                                                                        # nothing pressed -> cancel
    [btn(pg.CONTROLLER_BUTTON_DPAD_DOWN)], [btn(pg.CONTROLLER_BUTTON_A)], [btn(pg.CONTROLLER_BUTTON_A, False)], "wait",  # Triangle
    [axis(5, 30000)], [axis(5, 0)], "wait",                                          # RT
    [btn(pg.CONTROLLER_BUTTON_DPAD_DOWN)], [btn(pg.CONTROLLER_BUTTON_X)],            # clear D-pad up
    [btn(pg.CONTROLLER_BUTTON_DPAD_UP)] * 8,   # wrap past "Reset" to Left stick Y
    [btn(pg.CONTROLLER_BUTTON_A)], [btn(pg.CONTROLLER_BUTTON_A, False)], "wait",
    [axis(3, -30000)], [axis(3, 0)], "wait",                                         # push RS up -> righty inverted
    "shot", [btn(pg.CONTROLLER_BUTTON_B)],
]
def events():
    if not plan: return [pg.event.Event(pg.QUIT)]
    p = plan.pop(0)
    if p == "wait": time.sleep(0.12); return []
    if p == "long": time.sleep(0.4); return []
    if p == "timeout": time.sleep(0.7); return []
    if p == "shot": pg.image.save(scr, "/tmp/bindings-shot.png"); return []
    return p
B.screen(pg, scr, (f, f, f), cfg, lambda c: saved.append(dict(c["bindings"]) if c.has_section("bindings") else {}), events=events)
g = lambda k: cfg.get("bindings", k)
check(g("circle") == "paddle1, b", "circle = paddle1, b  (got %r)" % g("circle"))
check(g("cross") == "a", "hold-to-cancel left cross alone (got %r)" % g("cross"))
check(g("square") == "x", "timeout left square alone")
check(g("triangle") == "righttrigger", "trigger bound (got %r)" % g("triangle"))
check(g("up") == "none", "clear")
check(g("ly") == "righty~", "stick bound inverted (got %r)" % g("ly"))
check(saved, "saved on exit")
print("%d FAILED" % fails if fails else "all bindings tests passed"); sys.exit(1 if fails else 0)
