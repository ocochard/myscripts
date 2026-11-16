#!/usr/bin/env python3
# Read OV05C10 page-0 registers (chip ID, clock set-up) on Linux while the
# ISP firmware streams, through the ISP's first I2C controller (DesignWare
# at ISP offset 0x66400) with amdgpu's debugfs register file.  This one
# writes the sensor's page register (0xfd): it waits for the end of a
# firmware I2C burst plus 1 ms of idle, switches to page 0, reads, checks
# the page is still 0 (no firmware write in between) and restores page 1.
# Run as root while a stream is running.
import os, struct, sys, time

I2C = 0x66400
PAGE0 = [0x00, 0x01, 0x02] + list(range(0x10, 0x30)) + [0xc0, 0xc1, 0xc2,
                                                         0xc3, 0xe7]
f = os.open('/sys/kernel/debug/dri/1/amdgpu_regs', os.O_RDWR)

def rd(off):
    return struct.unpack('<I', os.pread(f, 4, off))[0]

def wr(off, v):
    os.pwrite(f, struct.pack('<I', v), off)

def idle():
    return (rd(I2C + 0x70) & 0x25 == 0x04 and rd(I2C + 0x74) == 0 and
            rd(I2C + 0x78) == 0)

def wait_rx():
    abrt0 = rd(I2C + 0x80)
    end = time.monotonic() + 0.01
    while time.monotonic() < end:
        if rd(I2C + 0x78) != 0:
            return rd(I2C + 0x10) & 0xff
        if rd(I2C + 0x80) != abrt0:
            raise IOError('abort 0x%x' % rd(I2C + 0x80))
    raise IOError('timeout')

def sensor_rd(reg):
    wr(I2C + 0x10, reg)
    wr(I2C + 0x10, 0x300)       # read, stop
    return wait_rx()

def sensor_wr(reg, val):
    wr(I2C + 0x10, reg)
    wr(I2C + 0x10, 0x200 | val)  # write, stop
    end = time.monotonic() + 0.01
    while not idle():
        if time.monotonic() > end:
            raise IOError('write timeout')

# Wait for a firmware burst to end, then 1 ms of quiet.
end = time.monotonic() + 1.0
seen_busy = False
while time.monotonic() < end:
    if not idle():
        seen_busy = True
        quiet = None
        continue
    if seen_busy:
        quiet = quiet or time.monotonic()
        if time.monotonic() - quiet > 0.001:
            break
else:
    sys.exit('no firmware I2C burst seen (busy=%s)' % seen_busy)
if rd(I2C + 0x04) & 0x3ff != 0x10 or rd(I2C + 0x9c) & 1 == 0:
    sys.exit('controller not aimed at the sensor')

t0 = time.monotonic()
page = sensor_rd(0xfd)
sensor_wr(0xfd, 0x00)
vals = {r: sensor_rd(r) for r in PAGE0}
still = sensor_rd(0xfd)
sensor_wr(0xfd, page)
after = sensor_rd(0xfd)
t1 = time.monotonic()
print('page before 0x%02x, during 0x%02x, restored 0x%02x, window %.1f ms' %
      (page, still, after, (t1 - t0) * 1000))
print(' '.join('%02x=%02x' % (r, v) for r, v in vals.items()))
