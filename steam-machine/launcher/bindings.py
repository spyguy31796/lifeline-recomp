"""Controller bindings for the Lifeline Recomp launcher (our code, MIT).

Config: [bindings] in config.ini, one line per PS2 input, e.g.
    circle = b, paddle1        # push-to-talk: B or a back paddle
    lx = leftx                 # sticks take a whole axis; '~' inverts (e.g. ly = righty~)
    up = dpup, -lefty          # digital inputs take buttons, axis directions (+/-), triggers,
    select = none              #   joy:bN / joy:aN+ / joy:hN.up (raw), key:<SDL key name>
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
ANALOG = {"lx", "ly", "rx", "ry"}
DEFAULTS = {"cross": "a", "circle": "b", "square": "x", "triangle": "y", "l1": "leftshoulder", "r1": "rightshoulder",
            "l2": "lefttrigger", "r2": "righttrigger", "l3": "leftstick", "r3": "rightstick", "select": "back",
            "start": "start", "up": "dpup", "down": "dpdown", "left": "dpleft", "right": "dpright",
            "lx": "leftx", "ly": "lefty", "rx": "rightx", "ry": "righty"}
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


def current(cfg, key):
    if cfg.has_section("bindings") and cfg.has_option("bindings", key):
        return cfg.get("bindings", key)
    return DEFAULTS[key]


def pretty(spec):
    out = []
    for s in [x.strip() for x in spec.split(",") if x.strip()]:
        inv = s.endswith("~"); b = s.rstrip("~"); sign = ""
        if b[:1] in "+-" and b[1:] in AXES: sign, b = b[0], b[1:]
        out.append((PRETTY.get(b, b) + sign + (" inverted" if inv else "")))
    return ", ".join(out) or "(none)"


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
    return ";".join("%s=%s" % (k, cfg.get("bindings", k)) for k, _ in TARGETS if cfg.has_option("bindings", k))


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
        if n: return [("key:" + n, t == pg.KEYDOWN)]
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


def screen(pg, scr, fonts, cfg, save, events=None):
    """Bindings screen. A = rebind, Y = add another input, X = clear, B = back (saves).
    Last row resets everything to the default layout."""
    F, S, T = fonts
    rows = TARGETS + [("__reset", "Reset all to defaults")]
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
                cap, mode = Capture(), ("replace" if name == "a" else "add"); cap.analog = key in ANALOG
            elif name == "x": set_binding(cfg, key, "none"); save(cfg); msg = "Cleared"
        if cap:
            r = cap.tick()
            if r:
                key = rows[sel][0]
                if r[0] == "bind":
                    (set_binding if mode == "replace" else add_binding)(cfg, key, r[1]); save(cfg)
                    msg = "%s -> %s" % (dict(TARGETS)[key], pretty(current(cfg, key)))
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
