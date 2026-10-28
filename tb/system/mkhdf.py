#!/usr/bin/env python3
# mkhdf.py FILE [SECTORS]: a test hard disk image, long word k of sector n
# holding n << 16 | k (big-endian, as the Amiga reads it); t_scsi checks it.
import struct, sys
n = int(sys.argv[2]) if len(sys.argv) > 2 else 8192
with open(sys.argv[1], 'wb') as f:
    for s in range(n):
        f.write(b''.join(struct.pack('>I', (s << 16) | k) for k in range(128)))
