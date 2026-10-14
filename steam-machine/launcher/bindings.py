"""Controller bindings for the Lifeline Recomp launcher (our code, MIT).

Config: [bindings] in config.ini, one line per PS2 input, e.g.
    circle = b, paddle1        # push-to-talk: B or a back paddle
    lx = leftx                 # sticks take a whole axis; '~' inverts (e.g. ly = righty~)
    up = dpup, -lefty          # digital inputs take buttons, axis directions (+/-), triggers,
    select = none              #   joy:bN / joy:aN+ / joy:hN.up (raw), key:<SDL key name>
Inline comments need a space before '#' (as above); both run.sh and the launcher strip them.
Keys ',', ';', '=' and '#' can't be bound (they are separators in the file / PS2_INPUT_MAP).
Hotkeys live in the same section: hk_fullscreen / hk_quit / hk_save / hk_load / hk_slot = chord[@hold_ms], chord...  where a chord is
inputs joined by '&' that must all be held, e.g. hk_quit = back&start@1500, key:Escape@1000.
run.sh turns the section into PS2_INPUT_MAP for ps2run (ourcode/input). No section = built-in layout.
"""
import time

# (key, label) in screen order. Digital first, sticks last.
TARGETS = [
    ("circle", "Circle (push-to-talk)"), ("cross", "Cross"), ("square", "Square"), ("triangle", "Triangle"),
    ("up", "D-pad up"), ("down", "D-pad down"), ("left", "D-pad left"), ("right", "D-pad right"),
    ("l1", "L1"), ("r1", "R1"), ("l2", "L2"), ("r2", "R2"), ("l3", "L3 (left stick click)"), ("r3", "R3 (right stick click)"),
    ("start", "START"), ("select", "SELECT"),
    ("lx", "Left stick X"), ("ly", "Left stick Y"), ("rx", "Right stick X"), ("ry", "Right stick Y"),
]
HOTKEYS = [("hk_fullscreen", "Hotkey: fullscreen"), ("hk_quit", "Hotkey: quit (hold)"),
           ("hk_save", "Hotkey: save state"), ("hk_load", "Hotkey: load state (hold)"), ("hk_slot", "Hotkey: next save slot")]
HOTKEY_DEFAULTS = {"hk_fullscreen": "key:F11, key:Alt&key:Return, back&rightstick",     # same as ourcode/input/input_map.cpp
                   "hk_quit": "key:Ctrl&key:Q@500, key:Escape@1000, back&start@1500",
                   "hk_save": "key:F5, back&rightshoulder@500",       # save slots (QoL item 4); never Circle
                   "hk_load": "key:F8@500, back&leftshoulder@1000",
                   "hk_slot": "key:F6, back&dpright"}
QUIT_HOLD_MS = 1500   # hold time given to a captured quit chord
HOLD_ON_CAPTURE = {"hk_quit": QUIT_HOLD_MS, "hk_save": 500, "hk_load": 1000}   # captured chords get these holds
MAX_HOLD_MS, MAX_CHORD = 10000, 4
ANALOG = {"lx", "ly", "rx", "ry"}
DEFAULTS = {"cross": "a", "circle": "b", "square": "x", "triangle": "y", "l1": "leftshoulder", "r1": "rightshoulder",
            "l2": "lefttrigger", "r2": "righttrigger", "l3": "leftstick", "r3": "rightstick", "select": "back",
            "start": "start", "up": "dpup", "down": "dpdown", "left": "dpleft", "right": "dpright",
            "lx": "leftx", "ly": "lefty", "rx": "rightx", "ry": "righty", **HOTKEY_DEFAULTS}
# SDL_GameControllerButton / Axis order (same tables as ourcode/input/input_map.cpp)
BUTTONS = ["a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick", "leftshoulder", "rightshoulder",
           "dpup", "dpdown", "dpleft", "dpright", "misc1", "paddle1", "paddle2", "paddle3", "paddle4", "touchpad"]
AXES = ["leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger"]
PRETTY = {"a": "A", "b": "B", "x": "X", "y": "Y", "back": "Back/View", "guide": "Guide", "start": "Start/Menu",
          "leftstick": "LS click", "rightstick": "RS click", "leftshoulder": "LB", "rightshoulder": "RB",
          "dpup": "D-pad up", "dpdown": "D-pad down", "dpleft": "D-pad left", "dpright": "D-pad right",
          "lefttrigger": "LT", "righttrigger": "RT", "leftx": "LS X", "lefty": "LS Y", "rightx": "RS X", "righty": "RS Y",
          "misc1": "Share", "paddle1": "Paddle 1", "paddle2": "Paddle 2", "paddle3": "Paddle 3", "paddle4": "Paddle 4",
          "touchpad": "Touchpad", "none": "(none)"}

HOLD_CANCEL = 1.5    # hold the pressed input this long to cancel instead of binding
TIMEOUT = 6.0        # nothing pressed -> cancel
SETTLE = 0.25        # all inputs must be released this long before listening (the A that opened capture)
AXIS_ON, AXIS_OFF = 0.6, 0.3


import re
_COMMENT = re.compile(r"\s+[#;].*$")
FORBIDDEN_KEYS = {",", ";", "=", "#", "&", "@"}


def strip_comment(v):
    return _COMMENT.sub("", v).strip()


def current(cfg, key):
    if cfg.has_section("bindings") and cfg.has_option("bindings", key):
        return strip_comment(cfg.get("bindings", key))
    return DEFAULTS[key]


_SRC = re.compile(r"^(?:[+-]?(?:%s)|(?:%s)~?|(?:%s)|joy:b(\d{1,3})|joy:a(\d{1,3})(?:[+-]|~)?|joy:h(\d{1,3})\.(?:up|down|left|right)|key:(.+))$"
                  % ("|".join(AXES), "|".join(AXES), "|".join(BUTTONS)))


def validate(target, spec):
    """Same rules as ourcode/input/input_map.cpp. Returns an error string, or "" if valid."""
    if target not in DEFAULTS: return "unknown input %r" % target
    spec = strip_comment(spec)
    if spec.lower() in ("", "none"): return ""
    if target in HOTKEY_DEFAULTS:
        for chord in [x.strip() for x in spec.split(",")]:
            if not chord: return "empty item in %r (stray ','?)" % spec
            keys, at, hold = chord.rpartition("@") if "@" in chord else (chord, "", "")
            if at and not (re.fullmatch(r"\s*\d+\s*", hold) and int(hold) <= MAX_HOLD_MS):
                return "bad hold time in %r (0-%d ms)" % (chord, MAX_HOLD_MS)
            parts = [k.strip() for k in keys.split("&")]
            if not 1 <= len(parts) <= MAX_CHORD: return "a hotkey takes 1-%d inputs: %r" % (MAX_CHORD, chord)
            for raw in parts:
                bad = _source_error(raw, analog=False)
                if bad: return bad
        return ""
    for raw in [x.strip() for x in spec.split(",")]:
        bad = _source_error(raw, target in ANALOG, target)
        if bad: return bad
    return ""


def _source_error(raw, analog, target="hotkey"):
    s = raw if raw.startswith("key:") else raw.lower()
    m = _SRC.match(s)
    if not m or not raw: return "unknown source %r" % raw
    if any(g is not None and int(g) > 255 for g in m.groups()[:3]):
        return "index out of range in %r" % raw
    if m.group(4) is not None and (not m.group(4).strip() or set(m.group(4)) & FORBIDDEN_KEYS):
        return "key %r can't be bound" % raw
    whole_axis = (s.rstrip("~") in AXES) or bool(re.match(r"^joy:a\d+~?$", s))
    if analog and not whole_axis: return "%s needs a whole axis, got %r" % (target, raw)
    if not analog and s.endswith("~"): return "'~' only applies to sticks: %r" % raw
    if s.lstrip("+-") in BUTTONS and s[:1] in "+-": return "'+'/'-' only applies to axes: %r" % raw
    return ""


def push_to_talk_warning(cfg, key, spec=None):
    """Hotkey chords that use a push-to-talk (circle) input: return a warning, or ""."""
    if key not in HOTKEY_DEFAULTS: return ""
    spec = current(cfg, key) if spec is None else strip_comment(spec)
    talk = {x.strip().lower() for x in current(cfg, "circle").split(",") if x.strip() and x.strip() != "none"}
    used = [k.strip() for chord in spec.split(",") for k in chord.rpartition("@")[0 if "@" in chord else 2].split("&")]
    hit = sorted({k for k in used if k.lower() in talk})
    if not hit: return ""
    return "Warning: %s is push-to-talk (Circle); it talks when pressed first and is held back from the game when pressed later" % ", ".join(pretty(h) for h in hit)


def pretty(spec):
    if "&" in spec or "@" in spec:   # hotkey chords
        out = []
        for chord in [x.strip() for x in spec.split(",") if x.strip()]:
            keys, _, hold = chord.rpartition("@") if "@" in chord else (chord, "", "")
            names = [_pretty_one(k.strip()) for k in keys.split("&")]
            out.append(" + ".join(names) + (" (hold %gs)" % (int(hold) / 1000.0) if hold.strip() not in ("", "0") else ""))
        return ", ".join(out) or "(none)"
    out = []
    for s in [x.strip() for x in spec.split(",") if x.strip()]:
        inv = s.endswith("~"); b = s.rstrip("~"); sign = ""
        if b[:1] in "+-" and b[1:] in AXES: sign, b = b[0], b[1:]
        out.append((PRETTY.get(b, b) + sign + (" inverted" if inv else "")))
    return ", ".join(out) or "(none)"


def _pretty_one(s):
    if s.startswith("key:"): return s[4:]
    return pretty(s)


def set_binding(cfg, key, spec):
    if not cfg.has_section("bindings"):
        cfg.add_section("bindings")
        for k, v in DEFAULTS.items(): cfg.set("bindings", k, v)   # write the full layout once edited
    cfg.set("bindings", key, spec)


def add_binding(cfg, key, src):
    cur = [x.strip() for x in current(cfg, key).split(",") if x.strip() and x.strip() != "none"]
    if src not in cur: cur.append(src)
    set_binding(cfg, key, ", ".join(cur))


def reset(cfg):
    if cfg.has_section("bindings"): cfg.remove_section("bindings")


def to_env(cfg):
    """The PS2_INPUT_MAP string run.sh would build (used by --dry-run / tests)."""
    if not cfg.has_section("bindings"): return ""
    return ";".join("%s=%s" % (k, current(cfg, k)) for k, _ in TARGETS + HOTKEYS if cfg.has_option("bindings", k))


def event_inputs(pg, e, analog, controller_ids):
    """Normalise one pygame event to [(source, is_down)] for the capture state machine."""
    t = e.type
    if t == pg.CONTROLLERBUTTONDOWN or t == pg.CONTROLLERBUTTONUP:
        if 0 <= e.button < len(BUTTONS): return [(BUTTONS[e.button], t == pg.CONTROLLERBUTTONDOWN)]
    elif t == pg.CONTROLLERAXISMOTION and 0 <= e.axis < len(AXES):
        name, v = AXES[e.axis], e.value / 32767.0
        if name.endswith("trigger"): return [(name, v > AXIS_ON)] if v > AXIS_ON or v < AXIS_OFF else []
        if analog: keys = {+1: name, -1: name + "~"}
        else: keys = {+1: "+" + name, -1: "-" + name}
        if abs(v) > AXIS_ON: return [(keys[1 if v > 0 else -1], True)]
        if abs(v) < AXIS_OFF: return [(keys[1], False), (keys[-1], False)]
    elif getattr(e, "instance_id", None) in controller_ids or getattr(e, "joy", None) in controller_ids:
        return []   # raw joystick events of a device we already read as a game controller
    elif t in (pg.JOYBUTTONDOWN, pg.JOYBUTTONUP) and not analog:
        return [("joy:b%d" % e.button, t == pg.JOYBUTTONDOWN)]
    elif t == pg.JOYAXISMOTION:
        v = e.value
        keys = {+1: "joy:a%d" % e.axis, -1: "joy:a%d~" % e.axis} if analog else {+1: "joy:a%d+" % e.axis, -1: "joy:a%d-" % e.axis}
        if abs(v) > AXIS_ON: return [(keys[1 if v > 0 else -1], True)]
        if abs(v) < AXIS_OFF: return [(keys[1], False), (keys[-1], False)]
    elif t == pg.JOYHATMOTION and not analog:
        x, y = e.value; out = []
        for d, on in (("up", y > 0), ("down", y < 0), ("left", x < 0), ("right", x > 0)):
            out.append(("joy:h%d.%s" % (e.hat, d), on))
        return out
    elif t in (pg.KEYDOWN, pg.KEYUP) and not analog:
        n = pg.key.name(e.key)
        if n and not (set(n) & FORBIDDEN_KEYS): return [("key:" + n, t == pg.KEYDOWN)]   # separators can't be bound
    return []


class Capture:
    """'Press an input to bind' state machine. Feed it normalised inputs; poll result().
    result: None while running, ("bind", src) or ("cancel", reason)."""

    def __init__(self, now=None):
        now = time.monotonic() if now is None else now
        self.held, self.phase, self.t, self.cand, self.res = set(), "settle", now, None, None
        self.quiet_since = now

    def feed(self, src, down, now=None):
        now = time.monotonic() if now is None else now
        if down: self.held.add(src)
        else: self.held.discard(src)
        if self.phase == "settle":
            self.quiet_since = now
        elif self.phase == "wait" and down:
            self.phase, self.cand, self.t = "held", src, now
        elif self.phase == "held" and not down and src == self.cand:
            self.res = ("bind", src)
        return self.tick(now)

    def tick(self, now=None):
        now = time.monotonic() if now is None else now
        if self.res: return self.res
        if self.phase == "settle" and not self.held and now - self.quiet_since >= SETTLE:
            self.phase, self.t = "wait", now
        elif self.phase == "wait" and now - self.t >= TIMEOUT:
            self.res = ("cancel", "timed out")
        elif self.phase == "held" and now - self.t >= HOLD_CANCEL:
            self.res = ("cancel", "held to cancel")
        return self.res

    analog = False

    def prompt(self, now=None):
        now = time.monotonic() if now is None else now
        if self.phase == "settle": return "Release all buttons..."
        if self.phase == "wait" and self.analog:
            return "Push a stick RIGHT (for X) or DOWN (for Y) - the other way binds it inverted (%.0fs left)" % max(0, TIMEOUT - (now - self.t))
        if self.phase == "wait": return "Press the input to bind (%.0fs left)   - hold any input %.1fs to cancel" % (max(0, TIMEOUT - (now - self.t)), HOLD_CANCEL)
        return "Release to bind %s  (keep holding to cancel)" % pretty(self.cand)


class ChordCapture(Capture):
    """Like Capture, but every input pressed together is recorded; the first release binds them all
    ("back&start"). Holding the chord CHORD_CANCEL seconds cancels."""

    CHORD_CANCEL = 4.0

    def __init__(self, hold_ms=0, now=None):
        super().__init__(now)
        self.chord, self.hold_ms = [], hold_ms

    def feed(self, src, down, now=None):
        now = time.monotonic() if now is None else now
        if self.phase in ("wait", "held") and down and src not in self.chord and len(self.chord) < MAX_CHORD:
            self.chord.append(src)
            if self.phase == "wait": self.phase, self.t = "held", now
        if down: self.held.add(src)
        else: self.held.discard(src)
        if self.phase == "settle": self.quiet_since = now
        elif self.phase == "held" and not down and src in self.chord and not self.res:
            self.res = ("bind", "&".join(self.chord) + ("@%d" % self.hold_ms if self.hold_ms else ""))
        return self.tick(now)

    def tick(self, now=None):
        now = time.monotonic() if now is None else now
        if not self.res and self.phase == "held" and now - self.t >= self.CHORD_CANCEL:
            self.res = ("cancel", "held to cancel")
        if self.phase == "held": return self.res
        return super().tick(now)

    def prompt(self, now=None):
        now = time.monotonic() if now is None else now
        if self.phase == "wait":
            return "Hold all buttons of the hotkey together, then release (%.0fs left)" % max(0, TIMEOUT - (now - self.t))
        if self.phase == "held": return "Release to bind %s  (keep holding to cancel)" % pretty("&".join(self.chord))
        return super().prompt(now)


def screen(pg, scr, fonts, cfg, save, events=None):
    """Bindings screen. A = rebind, Y = add another input, X = clear, B = back (saves).
    Last row resets everything to the default layout."""
    F, S, T = fonts
    rows = TARGETS + HOTKEYS + [("__reset", "Reset all to defaults")]
    sel, cap, msg, clock = 0, None, "", pg.time.Clock()
    ctl_ids = set()
    for i in range(pg.joystick.get_count()):
        try:
            if pg._sdl2.controller.is_controller(i): ctl_ids.add(pg.joystick.Joystick(i).get_instance_id())
        except Exception: pass
    mode = "replace"
    get = events or pg.event.get
    while True:
        for e in get():
            if e.type == pg.QUIT: return
            key = rows[sel][0]
            if cap:
                for src, down in event_inputs(pg, e, key in ANALOG, ctl_ids): cap.feed(src, down)
                continue
            name = None
            if e.type == pg.CONTROLLERBUTTONDOWN:
                name = {pg.CONTROLLER_BUTTON_A: "a", pg.CONTROLLER_BUTTON_B: "b", pg.CONTROLLER_BUTTON_X: "x",
                        pg.CONTROLLER_BUTTON_Y: "y", pg.CONTROLLER_BUTTON_DPAD_UP: "up", pg.CONTROLLER_BUTTON_DPAD_DOWN: "down"}.get(e.button)
            elif e.type == pg.KEYDOWN:
                name = {pg.K_UP: "up", pg.K_DOWN: "down", pg.K_RETURN: "a", pg.K_ESCAPE: "b", pg.K_BACKSPACE: "b",
                        pg.K_DELETE: "x", pg.K_INSERT: "y"}.get(e.key)
            if not name: continue
            msg = ""
            if name == "up": sel = (sel - 1) % len(rows)
            elif name == "down": sel = (sel + 1) % len(rows)
            elif name == "b": save(cfg); return
            elif key == "__reset":
                if name == "a": reset(cfg); save(cfg); msg = "Default layout restored"
            elif name in ("a", "y"):
                if key in HOTKEY_DEFAULTS: cap = ChordCapture(HOLD_ON_CAPTURE.get(key, 0))
                else: cap = Capture(); cap.analog = key in ANALOG
                mode = "replace" if name == "a" else "add"
            elif name == "x": set_binding(cfg, key, "none"); save(cfg); msg = "Cleared"
        if cap:
            r = cap.tick()
            if r:
                key = rows[sel][0]
                if r[0] == "bind":
                    (set_binding if mode == "replace" else add_binding)(cfg, key, r[1]); save(cfg)
                    msg = "%s -> %s" % (dict(TARGETS + HOTKEYS)[key], pretty(current(cfg, key)))
                    msg = push_to_talk_warning(cfg, key) or msg
                else: msg = "Cancelled (%s)" % r[1]
                cap = None; pg.event.clear()
        W, H = scr.get_size(); scr.fill((12, 14, 18))
        scr.blit(T.render("CONTROLLER BINDINGS", True, (220, 60, 50)), (60, 30))
        rowh, top = 34, 110; vis = max(1, (H - 220) // rowh)
        first = max(0, min(sel - vis // 2, len(rows) - vis))
        for i, (k, lbl) in enumerate(rows[first:first + vis], first):
            y = top + (i - first) * rowh
            if i == sel: pg.draw.rect(scr, (50, 60, 80), (40, y - 4, W - 80, rowh))
            scr.blit(F.render(lbl, True, (240, 240, 240)), (60, y))
            if k != "__reset": scr.blit(F.render(pretty(current(cfg, k)), True, (120, 200, 255)), (W // 2, y))
        if cap: scr.blit(S.render(cap.prompt(), True, (255, 220, 90)), (60, H - 90))
        else: scr.blit(S.render(msg, True, (230, 200, 90)), (60, H - 90))
        scr.blit(S.render("A: rebind   Y: add another   X: clear   B: back (saved)", True, (140, 140, 140)), (60, H - 50))
        pg.display.flip(); clock.tick(60)
