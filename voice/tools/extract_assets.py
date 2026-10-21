#!/usr/bin/env python3
"""Voice assets (context/word tables) from YOUR OWN ISO, for build.sh (Linux) and windows/install.ps1.

usage: extract_assets.py <OS.FAT> <iso> <out-dir>
  OS.FAT   from the ISO via upstream scripts/disc.py (extract <iso> <dir> OS.FAT)
  iso      your ISO, read only (pass the real path; no symlink needed)
  out-dir  created if missing; one folder per archive

arcx.py and fat.py (same folder) have the dev-box paths baked in. They are run unmodified except that each
quoted dev-box path literal is replaced by a variable name, and the variables get the paths from argv. No path
text is pasted into Python source, so Windows backslashes, quotes and non-ASCII characters are safe.
Same output as the inline wrapper build.sh used before. Stdlib only. Contains no game data.
"""
import contextlib, io, os, sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
FAT_EXEC = "exec(open(os.path.join(os.path.dirname(__file__),'fat.py')).read().split('for e in ents')[0])"
# quoted literals exactly as they appear in fat.py / arcx.py (dev-box paths, not used on any install)
DEV_FAT = "'<repo-root>/private/iso/OS.FAT'"
DEV_ISO = "'<repo-root>/dump/Life Line (USA).iso'"
DEV_OUT = "'<repo-root>/private/asr_files'"


def _swap(src, literal, name, what):
    if literal not in src:
        sys.exit("extract_assets: %s no longer contains %s; update extract_assets.py" % (what, literal))
    return src.replace(literal, name)


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__.strip().splitlines()[2])
    fat, iso, out = (os.path.abspath(a) for a in argv)
    src = open(os.path.join(TOOLS, 'arcx.py')).read()
    fatsrc = open(os.path.join(TOOLS, 'fat.py')).read().split('for e in ents')[0]
    src = _swap(src, FAT_EXEC, 'exec(FATSRC)', 'arcx.py')
    fatsrc = _swap(fatsrc, DEV_FAT, 'LIFELINE_FAT_PATH', 'fat.py')
    src = _swap(src, DEV_ISO, 'LIFELINE_ISO_PATH', 'arcx.py')
    src = _swap(src, DEV_OUT, 'LIFELINE_OUT_DIR', 'arcx.py')
    g = {'__file__': os.path.join(TOOLS, 'arcx.py'), '__name__': '__main__', 'FATSRC': fatsrc,
         'LIFELINE_FAT_PATH': fat, 'LIFELINE_ISO_PATH': iso, 'LIFELINE_OUT_DIR': out}
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile(src, 'arcx.py', 'exec'), g)
    print('voice assets:', len(os.listdir(out)), 'folders')


if __name__ == '__main__':
    main(sys.argv[1:])
