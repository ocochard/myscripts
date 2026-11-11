/*
 * Read-only probe: read DEVID (0x0) and REVID (0x4) of the CS35L54 amps.
 * Registers are 32-bit addresses with 32-bit big-endian values.
 */
#include <sys/types.h>
#include <sys/ioctl.h>
#include <dev/iicbus/iic.h>
#include <err.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int
rd32(int fd, uint8_t addr, uint32_t reg, uint32_t *val)
{
	uint8_t w[4] = { reg >> 24, reg >> 16, reg >> 8, reg };
	uint8_t r[4];
	struct iic_msg msgs[2] = {
		{ addr << 1, IIC_M_WR, sizeof(w), w },
		{ addr << 1, IIC_M_RD, sizeof(r), r },
	};
	struct iic_rdwr_data d = { msgs, 2 };

	if (ioctl(fd, I2CRDWR, &d) < 0)
		return (-1);
	*val = (uint32_t)r[0] << 24 | r[1] << 16 | r[2] << 8 | r[3];
	return (0);
}

int
main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/iic1";
	uint32_t devid, revid;
	int fd;

	if ((fd = open(dev, O_RDWR)) < 0)
		err(1, "%s", dev);
	for (uint8_t a = 0x30; a <= 0x33; a++) {
		if (rd32(fd, a, 0x0, &devid) < 0) {
			printf("0x%02x: no answer\n", a);
			continue;
		}
		if (rd32(fd, a, 0x4, &revid) < 0)
			revid = 0xffffffff;
		printf("0x%02x: DEVID 0x%08x REVID 0x%08x\n", a, devid, revid);
	}
	close(fd);
	return (0);
}
