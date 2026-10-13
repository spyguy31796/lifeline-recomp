import struct
d=open('<repo-root>/private/iso/OS.FAT','rb').read()
n=struct.unpack('<I',d[8:12])[0]
ents=[]
for i in range(n):
    o=0x80+i*0x30
    name=d[o:o+16].split(b'\0')[0].decode('latin1')
    size,_,lba,cnt,fl,parent,me,_x=struct.unpack('<8I',d[o+16:o+48])
    ents.append((i,name,size,lba,cnt,fl,parent,me))
for e in ents: print(*e[:2],hex(e[2]),e[3],e[4],hex(e[5]),hex(e[6]),hex(e[7]))
