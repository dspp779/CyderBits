"""Small x86 PE header fixture for the cnc-ddraw architecture gate."""
import struct
import sys
from pathlib import Path

header = bytearray(512)
header[:2] = b"MZ"
struct.pack_into("<I", header, 60, 128)
header[128:132] = b"PE\0\0"
struct.pack_into("<H", header, 132, 0x14C)
struct.pack_into("<H", header, 150, 0x0102)
struct.pack_into("<H", header, 152, 0x10B)
Path(sys.argv[1]).write_bytes(header)
