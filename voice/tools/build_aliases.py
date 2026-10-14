#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build a local spoken-form alias table for the Lifeline voice module.

Run this yourself against the phrase tables you extracted from your own disc. It finds words in
the game's .vgp phrase tables that the Vosk model cannot recognize (not in its vocabulary) and
proposes a spoken form made of in-vocabulary words. Nothing game-specific is embedded here: every
alias is derived at run time from your files and the model.

  build_aliases.py --assets $PS2_VOICE_ASSETS --model $PS2_VOICE_VOSK_MODEL [--out FILE]

Output (default $PS2_VOICE_ASSETS/aliases.tsv): "token<TAB>spoken form<TAB># method score".
Tokens it cannot resolve are written to aliases.unresolved.txt next to it. Put your own fixes in
aliases.local.tsv (same two-column format, in the same folder); they override generated entries
here and at run time. Uses espeak-ng (if installed) to compare pronunciations; otherwise spelling only.
"""
import argparse, glob, os, re, shutil, struct, subprocess, sys

# ---- inputs -------------------------------------------------------------------------------
def parse_vgp(b):
    if b[:4] != b'VGP ': return []
    first = struct.unpack_from('<I', b, 0x18)[0]; out = []
    for o in range(0x10, first - 15, 16):
        l8 = struct.unpack_from('<H', b, o + 4)[0]; off = struct.unpack_from('<I', b, o + 8)[0]
        out.append(b[off:off + l8 * 8].split(b'\0')[0])
    return out

def _symtab(b, q):
    """OpenFst symbol table at q -> ({key: word}, end offset)."""
    q += 4; n = struct.unpack_from('<i', b, q)[0]; q += 4 + n
    _, size = struct.unpack_from('<qq', b, q); q += 16; d = {}
    for _ in range(size):
        l = struct.unpack_from('<i', b, q)[0]; w = b[q + 4:q + 4 + l].decode('utf8', 'replace'); q += 4 + l
        d[struct.unpack_from('<q', b, q)[0]] = w; q += 8
    return d, q

def _ngram_unigrams(b, q, syms):
    """Unigram costs (-log prob) from an OpenFst NGramFst body starting at q, or {} if the layout is unexpected."""
    try:
        S, F, NF = struct.unpack_from('<3Q', b, q); q += 24
        words = lambda bits: (bits + 63) // 64 * 8
        fut = q + words(2 * S + 1)
        fbits = b[fut:fut + words(F + S + 1)]
        bit = lambda i: fbits[i >> 3] >> (i & 7) & 1
        z0 = next(i for i in range(len(fbits) * 8) if not bit(i))
        z1 = next(i for i in range(z0 + 1, len(fbits) * 8) if not bit(i))
        k = z1 - z0 - 1
        q = fut + words(F + S + 1) + words(S) + 4 * S
        fw = struct.unpack_from(f'<{k}i', b, q)
        q += 4 * F + 4 * S + 4 * NF
        for shift in range(4):  # tolerate alignment padding: pick the offset where "the" is among the most likely words
            fp = struct.unpack_from(f'<{k}f', b, q + 4 * shift)
            u = {syms.get(w, ''): c for w, c in zip(fw, fp)}
            if sorted(u, key=u.get)[:10].count('the'): return u
    except Exception:
        pass
    return {}

def model_vocab(model):
    """(vocabulary set, unigram cost dict). Costs are empty if the graph has no readable n-gram model."""
    wt = os.path.join(model, 'graph', 'words.txt')
    for fst in ('Gr.fst', 'HCLG.fst'):  # OpenFst files embed their symbol tables
        p = os.path.join(model, 'graph', fst)
        if not os.path.exists(p): continue
        b = open(p, 'rb').read()
        q = 4
        for _ in range(2): q += 4 + struct.unpack_from('<i', b, q)[0]           # fst type, arc type
        flags = struct.unpack_from('<i', b, q + 4)[0]; q += 8 + 32
        if not flags & 1: continue
        syms, q = _symtab(b, q)
        if flags & 2: _, q = _symtab(b, q)
        V = {w for w in syms.values() if w and not w.startswith(('<', '#', '!'))}
        return V, (_ngram_unigrams(b, q, syms) if fst == 'Gr.fst' else {})
    if os.path.exists(wt):
        return {l.split()[0] for l in open(wt, encoding='utf8', errors='replace') if l.strip()}, {}
    sys.exit('cannot find the model vocabulary (graph/words.txt or a symbol table in graph/*.fst)')

def tokens(phrase):  # same normalization as speech_forms.cpp normalize_phrase
    return re.sub(r"[^a-z0-9']+", ' ', phrase.lower()).split()

# Generic English contraction rules; keep in sync with speech_forms.cpp (expand_contraction).
CONTRACTIONS = [("n't", " not"), ("'re", " are"), ("'ve", " have"), ("'ll", " will"), ("'d", " would"), ("'m", " them")]
def generic(t, V):
    if t.endswith("in'") and t[:-1] + 'g' in V: return t[:-1] + 'g'
    t = t.strip("'")
    if not t or t in V: return t
    if t.endswith("'s") and t[:-2] in V: return t[:-2]          # possessive / is
    for suf, rep in CONTRACTIONS:
        if t.endswith(suf) and t[:-len(suf)] in V and suf != "n't": return t[:-len(suf)] + rep
    return None

# ---- candidate generation -------------------------------------------------------------------
ALPHA = "abcdefghijklmnopqrstuvwxyz'"
def edits1(w):
    s = [(w[:i], w[i:]) for i in range(len(w) + 1)]
    return set([a + b[1:] for a, b in s if b] + [a + b[1] + b[0] + b[2:] for a, b in s if len(b) > 1] +
               [a + c + b[1:] for a, b in s if b for c in ALPHA] + [a + c + b for a, b in s for c in ALPHA])

def near(w, V, maxd):
    """In-vocabulary words within edit distance maxd (1 or 2), with their distance."""
    e1 = edits1(w); out = {x: 1 for x in e1 if x in V}
    if maxd >= 2 and len(w) >= 5:
        for x in e1:
            for y in edits1(x):
                if y in V and y not in out and y != w: out[y] = 2
    return out

def splits(w, V, depth=3):
    """Segmentations of w into up to `depth` pieces; pieces in vocab (cost 0) or 1 edit away (cost 1)."""
    res = []
    def ok(p):
        out = [(p, 0)] if p in V and (len(p) >= 2 or p in ('a', 'i')) else []
        if len(p) >= 2:  # also near spellings, most common first ("yu" -> "you")
            out += sorted(((x, 1) for x in near(p, V, 1) if len(x) >= 2), key=lambda c: UNI.get(c[0], 20.0))[:6]
        return out
    def rec(rest, acc, cost):
        if not rest:
            if len(acc) > 1: res.append((' '.join(acc), cost))
            return
        if len(acc) >= depth or cost > 1: return
        for i in range(1, len(rest) + 1):
            for p, c in ok(rest[:i]): rec(rest[i:], acc + [p], cost + c)
    rec(w, [], 0)
    return res

# ---- pronunciation scoring (optional espeak-ng) ---------------------------------------------
class Phon:
    def __init__(self):
        self.exe = shutil.which('espeak-ng') or shutil.which('espeak'); self.cache = {}
    def get(self, items):
        need = [x for x in items if x not in self.cache]
        if self.exe and need:
            for i in range(0, len(need), 500):
                chunk = need[i:i + 500]
                out = subprocess.run([self.exe, '-q', '-x', '-v', 'en-us'], input='\n'.join(chunk) + '\n',
                                     capture_output=True, text=True).stdout.splitlines()
                out = [o for o in out if o.strip()]
                if len(out) != len(chunk): out = [None] * len(chunk)
                for k, v in zip(chunk, out):
                    self.cache[k] = re.sub(r"[ ',%=_:;]|[0-9]", '', v) if v else None
        return [self.cache.get(x) for x in items]

def lev(a, b):
    p = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        c = [i]
        for j, cb in enumerate(b, 1): c.append(min(p[j] + 1, c[j - 1] + 1, p[j - 1] + (ca != cb)))
        p = c
    return p[-1]

def resolve(t, V, ph):
    g = generic(t, V)
    if g: return g, 'generic', 0.0
    cands = [(w, d, 'respell') for w, d in near(t, V, 2).items()] + [(s, c, 'split') for s, c in splits(t, V)]
    if not cands: return None, 'none', 9
    tp, = ph.get([t]); cp = ph.get([c[0] for c in cands]); best = None
    for (w, d, how), p in zip(cands, cp):
        if tp and p: score = lev(tp, p) / max(len(tp), 1) + 0.05 * d     # pronunciation first
        else: score = 0.25 * d + (0.1 if how == 'split' else 0)          # spelling only
        score += 0.08 * w.count(' ') + 0.1 * sum(len(x) == 1 for x in w.split()) + (0.15 if w[0] != t[0] else 0)
        if UNI:  # prefer common words: penalize each piece by how rare it is in the model's language model
            score += sum(0.04 * max(0.0, UNI.get(x, 20.0) - 8.0) for x in w.split())
        if best is None or score < best[2]: best = (w, how, score)
    lim = (0.45 if tp else 0.5) + (0.35 if UNI else 0)
    return best if best[2] <= lim else (None, 'weak:' + best[0], best[2])

UNI = {}

def write_atomic(path, text):
    """Write to a temp file in the same folder, then rename, so a crash never leaves a truncated file."""
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        f.write(text); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--assets', default=os.environ.get('PS2_VOICE_ASSETS'))
    ap.add_argument('--model', default=os.environ.get('PS2_VOICE_VOSK_MODEL'))
    ap.add_argument('--out')
    a = ap.parse_args()
    if not a.assets or not a.model: ap.error('need --assets and --model (or PS2_VOICE_ASSETS / PS2_VOICE_VOSK_MODEL)')
    out = a.out or os.path.join(a.assets, 'aliases.tsv')
    V, U = model_vocab(a.model)
    global UNI; UNI = U
    toks = set()
    for f in glob.glob(os.path.join(a.assets, '**', '*.vgp'), recursive=True):
        for p in parse_vgp(open(f, 'rb').read()):
            try: s = p.decode('ascii')
            except UnicodeDecodeError: continue
            for t in tokens(s):
                t = re.sub(r'(?<=[a-z])[0-9]+$', '', t)   # variant markers like word2 (handled in code too)
                if re.search('[a-z]', t) and not t.isdigit() and t.strip("'") not in V: toks.add(t)
    ph = Phon(); rows, bad = [], []
    for t in sorted(toks):
        w, how, sc = resolve(t, V, ph)
        (rows.append(f"{t}\t{w}\t# {how} {sc:.2f}") if w else bad.append(f"{t}\t# {how} {sc:.2f}"))
    write_atomic(out, '# generated by build_aliases.py - local file, do not distribute\n' + '\n'.join(rows) + '\n')
    up = os.path.join(os.path.dirname(out), 'aliases.unresolved.txt')
    write_atomic(up, '# add fixes to aliases.local.tsv as: token<TAB>spoken words\n' + '\n'.join(bad) + '\n')
    print(f"{len(toks)} out-of-vocabulary tokens: {len(rows)} aliased -> {out}, {len(bad)} unresolved -> {up}"
          f"{'' if ph.exe else ' (espeak-ng not found: spelling-only scoring)'}")

if __name__ == '__main__':
    main()
