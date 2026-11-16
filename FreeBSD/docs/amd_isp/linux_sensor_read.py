#!/usr/bin/env python3
# Read OV05C10 sensor registers on Linux through the ISP's first I2C
# controller (DesignWare at ISP offset 0x66400) that the ISP firmware
# drives, with amdgpu's debugfs register file.  Same sequence as amdisp's
# hw.amdisp.sensor sysctl on FreeBSD: only when the controller is enabled,
# idle, with empty FIFOs and already aimed at the sensor (IC_TAR 0x10);
# the sensor page register (0xfd) is never written.
# Run as root while a stream is running.
import os, struct, sys, time

I2C = 0x66400
REGS = [0xfd, 0x02, 0x03, 0x04, 0x05, 0x06, 0x35, 0x36, 0x37, 0x38]
f = os.open(sys.argv[1] if len(sys.argv) > 1 else
            '/sys/kernel/debug/dri/1/amdgpu_regs', os.O_RDWR)

def rd(off):
    return struct.unpack('<I', os.pread(f, 4, off))[0]

def wr(off, v):
    os.pwrite(f, struct.pack('<I', v), off)

def sensor_rd(reg):
    end = time.monotonic() + 0.02
    while True:
        st = rd(I2C + 0x70)
        if st & 0x25 == 0x04 and rd(I2C + 0x74) == 0 and rd(I2C + 0x78) == 0:
            break
        if time.monotonic() > end:
            return 'busy'
    if rd(I2C + 0x9c) & 1 == 0:
        return 'disabled'
    if rd(I2C + 0x04) & 0x3ff != 0x10:
        return 'tar 0x%x' % rd(I2C + 0x04)
    abrt0 = rd(I2C + 0x80)
    wr(I2C + 0x10, reg)
    wr(I2C + 0x10, 0x300)       # read, stop
    end = time.monotonic() + 0.02
    while time.monotonic() < end:
        if rd(I2C + 0x78) != 0:
            return '0x%02x' % (rd(I2C + 0x10) & 0xff)
        a = rd(I2C + 0x80)
        if a != abrt0:
            return 'abort 0x%x' % a
    return 'timeout'

print('i2c con 0x%x tar 0x%x en 0x%x st 0x%x' % (rd(I2C), rd(I2C + 0x04),
      rd(I2C + 0x9c), rd(I2C + 0x70)))
for p in range(3):
    print('sensor %d' % p, ' '.join('%02x=%s' % (r, sensor_rd(r))
          for r in REGS))
