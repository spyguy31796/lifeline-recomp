#!/usr/bin/env python3
"""Voice assets (context/word tables) from YOUR OWN ISO, for build.sh (Linux) and windows/install.ps1.

usage: extract_assets.py <OS.FAT> <iso> <out-dir>
  OS.FAT   from the ISO via upstream scripts/disc.py (extract <iso> <dir> OS.FAT)
  iso      your ISO, read only (pass the real path; no symlink needed)
  out-dir  created if missing; one folder per archive

Calls arcx.extract() (arcx.py and fat.py, same folder) with the three paths from argv. Paths are only ever passed
as values, never pasted into Python source, so Windows backslashes, quotes and non-ASCII characters are safe.
Stdlib only. Contains no game data.
"""
import os, sys

TOOLS = os.path.dirname(os.path.abspath(__file__))


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__.strip().splitlines()[2])
    fat, iso, out = (os.path.abspath(a) for a in argv)
    sys.path.insert(0, TOOLS)   # python -I does not add the script folder
    import arcx
    arcx.extract(fat, iso, out)
    print('voice assets:', len(os.listdir(out)), 'folders')


if __name__ == '__main__':
    main(sys.argv[1:])
