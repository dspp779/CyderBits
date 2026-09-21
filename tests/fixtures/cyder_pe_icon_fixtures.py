"""Construct minimal inert PE resource fixtures; they contain no executable code."""
import pathlib,struct,sys,zlib
root=pathlib.Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
def chunk(kind,data): return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\xff\0\0\xff'*2)*2))+chunk(b'IEND',b'')
dib=struct.pack('<IiiHHIIiiII',40,2,4,1,32,0,16,0,0,0,0)+b'\0\0\xff\xff'*4+b'\0'*8
def pe(payload,bits=64):
 d=bytearray(1024)
 def w16(o,v):struct.pack_into('<H',d,o,v)
 def w32(o,v):struct.pack_into('<I',d,o,v)
 d[:2]=b'MZ';w32(60,0x80);d[0x80:0x84]=b'PE\0\0';w16(0x84,0x8664 if bits==64 else 0x14c);w16(0x86,1)
 opt=0x98;osize=240 if bits==64 else 224;w16(0x94,osize);w16(opt,0x20b if bits==64 else 0x10b)
 dirs=opt+(112 if bits==64 else 96);w32(dirs-4,16);w32(dirs+16,0x3000);w32(dirs+20,512)
 sec=opt+osize;d[sec:sec+5]=b'.rsrc';w32(sec+8,512);w32(sec+12,0x3000);w32(sec+16,512);w32(sec+20,512)
 r=512
 def directory(off,entries):
  w16(r+off+14,len(entries))
  for i,(name,target) in enumerate(entries):w32(r+off+16+i*8,name);w32(r+off+20+i*8,target)
 directory(0,[(3,0x80000030),(14,0x80000050)])
 directory(0x30,[(1,0x80000070)]);directory(0x50,[(101,0x80000090)])
 directory(0x70,[(1033,0xb0)]);directory(0x90,[(1033,0xc0)])
 w32(r+0xb0,0x3100);w32(r+0xb4,len(payload));w32(r+0xc0,0x30e0);w32(r+0xc4,20)
 d[r+0xe0:r+0xf4]=struct.pack('<HHHBBBBHHIH',0,1,1,2,2,0,0,1,32,len(payload),1)
 d[r+0x100:r+0x100+len(payload)]=payload
 return d
for bits in [32,64]:
 for kind,payload in [('png',png),('dib',dib)]: (root/f'{kind}-{bits}.exe').write_bytes(pe(payload,bits))
base=pe(png)
for name,offset,value in [('bad-rva',512+0xb0,0xffffffff),('directory-cycle',512+20,0x80000000),('length-mismatch',512+0xb4,999999),('huge-entry-count',512+12,0xffffffff)]:
 d=bytearray(base);struct.pack_into('<I',d,offset,value);(root/f'{name}.exe').write_bytes(d)
(root/'truncated.exe').write_bytes(base[:700]);(root/'not-pe.exe').write_bytes(b'x'*1024)
(root/'expected.png').write_bytes(png)
