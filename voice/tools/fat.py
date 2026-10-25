#!/usr/bin/env python3
"""List the entries of OS.FAT, the file table read from YOUR OWN disc. Stdlib only; contains no game data.

usage: fat.py [OS.FAT]
  OS.FAT  from your ISO via upstream scripts/disc.py (extract <iso> <dir> OS.FAT);
          if omitted, the LIFELINE_FAT environment variable is used
"""
import os, struct, sys


def read_fat(path):
    """Return the table as (index, name, size, lba, count, flags, parent, self) tuples."""
    with open(path, 'rb') as f:
        d = f.read()
    n = struct.unpack('<I', d[8:12])[0]
    ents = []
    for i in range(n):
        o = 0x80 + i * 0x30
        name = d[o:o + 16].split(b'\0')[0].decode('latin1')
        size, _, lba, cnt, fl, parent, me, _x = struct.unpack('<8I', d[o + 16:o + 48])
        ents.append((i, name, size, lba, cnt, fl, parent, me))
    return ents


def main(argv):
    if argv and argv[0] in ('-h', '--help'):
        print(__doc__.strip()); return
    if len(argv) > 1:
        sys.exit('fat.py: too many arguments\n\n' + __doc__.strip())
    path = argv[0] if argv else os.environ.get('LIFELINE_FAT')
    if not path:
        sys.exit('fat.py: no OS.FAT given (pass it as an argument or set LIFELINE_FAT)\n\n' + __doc__.strip())
    for e in read_fat(path):
        print(*e[:2], hex(e[2]), e[3], e[4], hex(e[5]), hex(e[6]), hex(e[7]))


if __name__ == '__main__':
    main(sys.argv[1:])
