#!/usr/bin/env python3
"""Extract the voice context/word table archives from YOUR OWN ISO. Stdlib only; contains no game data.

usage: arcx.py [OS.FAT] [iso] [out-dir]
  OS.FAT   from your ISO via upstream scripts/disc.py   (default: env LIFELINE_FAT)
  iso      your ISO, read only                          (default: env LIFELINE_ISO)
  out-dir  created if missing; one folder per archive   (default: env LIFELINE_ASSETS_OUT)
Prints one line per extracted archive. build.sh and windows/install.ps1 call extract_assets.py, which uses extract().
"""
import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # also under python -I
from fat import read_fat


def extract(fat_path, iso_path, out_dir):
    """Write each matching archive's members to out_dir/<archive>/; return [(archive, [member names])]."""
    ents = read_fat(fat_path)
    os.makedirs(out_dir, exist_ok=True)
    summary = []
    with open(iso_path, 'rb') as iso:
        for e in ents:
            i, name, size, lba, cnt, fl, a, b = e
            if fl & 0x10 or size == 0: continue
            iso.seek((lba + 1624) * 2048); h = iso.read(16)
            if h[:3] != b'arc': continue
            n, ds = struct.unpack('<II', h[8:16])
            iso.seek((lba + 1624) * 2048); hdr = iso.read(16 + 0x30 * n)
            off = ds; ents2 = []
            for k in range(n):
                o = 16 + 0x30 * k; nm = hdr[o:o + 16].split(b'\0')[0].decode('latin1')
                asz = struct.unpack('<I', hdr[o + 16:o + 20])[0]; rsz = struct.unpack('<I', hdr[o + 0x24:o + 0x28])[0]
                ents2.append((nm, off, rsz)); off += asz
            if any(x[0].lower().endswith(('.wrd', '.ctx', '.vgp', '.lng', '.grm', '.bin')) and ('ctx' in x[0] or 'wrd' in x[0] or 'vgp' in x[0]) for x in ents2) or 'asr' in name.lower():
                d = os.path.join(out_dir, name); os.makedirs(d, exist_ok=True)
                for nm, o, rsz in ents2:
                    iso.seek((lba + 1624) * 2048 + o)
                    with open(os.path.join(d, nm), 'wb') as f:
                        f.write(iso.read(rsz))
                summary.append((name, [x[0] for x in ents2]))
    return summary


def main(argv):
    if argv and argv[0] in ('-h', '--help'):
        print(__doc__.strip()); return
    if len(argv) > 3:
        sys.exit('arcx.py: too many arguments\n\n' + __doc__.strip())
    env = ('LIFELINE_FAT', 'LIFELINE_ISO', 'LIFELINE_ASSETS_OUT')
    vals = [argv[k] if k < len(argv) else os.environ.get(env[k]) for k in range(3)]
    missing = [env[k] for k in range(3) if not vals[k]]
    if missing:
        sys.exit('arcx.py: missing %s (pass OS.FAT, iso and out-dir as arguments or set the environment variables)\n\n%s'
                 % (', '.join(missing), __doc__.strip()))
    for s in extract(*vals): print(s)


if __name__ == '__main__':
    main(sys.argv[1:])
