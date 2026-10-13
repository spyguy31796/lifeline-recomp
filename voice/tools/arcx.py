import struct,os,sys
sys.path.insert(0,os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__),'fat.py')).read().split('for e in ents')[0])
# build paths
byoff={0x80+e[0]*0x30:e for e in ents}
iso=open('<repo-root>/dump/Life Line (USA).iso','rb')
out='<repo-root>/private/asr_files'; os.makedirs(out,exist_ok=True)
summary=[]
for e in ents:
    i,name,size,lba,cnt,fl,a,b=e
    if fl&0x10 or size==0: continue
    iso.seek((lba+1624)*2048); h=iso.read(16)
    if h[:3]!=b'arc': continue
    n,ds=struct.unpack('<II',h[8:16])
    iso.seek((lba+1624)*2048); hdr=iso.read(16+0x30*n)
    off=ds; ents2=[]
    for k in range(n):
        o=16+0x30*k; nm=hdr[o:o+16].split(b'\0')[0].decode('latin1')
        asz=struct.unpack('<I',hdr[o+16:o+20])[0]; rsz=struct.unpack('<I',hdr[o+0x24:o+0x28])[0]
        ents2.append((nm,off,rsz)); off+=asz
    if any(x[0].lower().endswith(('.wrd','.ctx','.vgp','.lng','.grm','.bin')) and ('ctx' in x[0] or 'wrd' in x[0] or 'vgp' in x[0]) for x in ents2) or 'asr' in name.lower():
        d=os.path.join(out,name); os.makedirs(d,exist_ok=True)
        for nm,o,rsz in ents2:
            iso.seek((lba+1624)*2048+o); open(os.path.join(d,nm),'wb').write(iso.read(rsz))
        summary.append((name,[x[0] for x in ents2]))
for s in summary: print(s)
