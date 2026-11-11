/*
 * Userland prototype for the CS35L54 speaker amplifiers of the HP ZBook
 * Ultra G1a (phase 1 of cs35l54_speaker_amp_plan.md).
 *
 * cs35l54_tool reset        pulse the shared reset line (GPIO 139, needs amdgpio)
 * cs35l54_tool info         wake each amp and print its identity and state
 * cs35l54_tool load [-nsv] DIR  download the DSP program and tuning files from
 *                           DIR (-n: print the program writes only, -s: skip
 *                           program memory, -v: verbose)
 * cs35l54_tool play [-v dB] wake, configure and start the amps (ROM firmware)
 * cs35l54_tool stop         pause the amps and let them hibernate
 * cs35l54_tool tone [Hz [s [dBFS]]] play a sine tone on /dev/dsp4, or $DSP
 * cs35l54_tool read REG...  read registers (hex) on every amp
 * cs35l54_tool write ADDR REG VAL  write one register (hex) on one amp
 *
 * The register sequence follows cs35l54_linux_i2c_trace_amp1.txt, without
 * the DSP program download.  Registers: 32-bit address, 32-bit big-endian
 * value.  The amps sit at 0x30-0x33 on the I2C controller \_SB_.I2CB; its
 * iic(4) unit number changes when amdgpu adds its buses first, so the tool
 * looks it up.
 *
 * Build: cc -Wall -o cs35l54_tool cs35l54_tool.c -lm -lgpio
 */
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/soundcard.h>
#include <sys/sysctl.h>
#include <dev/iicbus/iic.h>
#include <err.h>
#include <fcntl.h>
#include <libgpio.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define	IIC_ACPI_PATH		"\\_SB_.I2CB"
#define	GPIO_ACPI_PATH		"\\_SB_.GPIO"
#define	GPIO_RESET_PIN		139
#define	DSP_DEV			"/dev/dsp4"
#define	AMP_FIRST		0x30
#define	AMP_COUNT		4

#define	REG_DEVID		0x0000000
#define	REG_REVID		0x0000004
#define	REG_OTPID		0x0000010
#define	REG_ASP1_ENABLES1	0x0004800
#define	REG_IRQ1_STATUS		0x000E004
#define	REG_MBOX		0x0011020
#define	REG_RESTRICT_STS1	0x00190F0
#define	REG_FW_VER		0x2800010
#define	REG_HALO_STATE		0x28021E0
#define	REG_USER_MUTE		0x3400024
#define	REG_USER_VOLUME		0x340002C
#define	REG_POSTURE		0x3400094
#define	REG_PROT_STS		0x34000D8
#define	REG_ACTUAL_PS		0x3400150

#define	MBOX_PLAY		0x0B000001
#define	MBOX_PAUSE		0x0B000002
#define	MBOX_PREVENT_HIBERNATE	0x02000003
#define	MBOX_ALLOW_HIBERNATE	0x02000004

#define	HALO_BOOT_DONE		2
#define	DEVID_CS35L54		0x35A54

struct reg_val {
	uint32_t reg;
	uint32_t val;
};

/* Register defaults Linux restores after boot, before the volume. */
static const struct reg_val patch[] = {
	{ 0x0004C70, 0x00000018 },	/* SWIRE_DP3_CH1_INPUT */
	{ 0x0004C74, 0x00000019 },	/* SWIRE_DP3_CH2_INPUT */
	{ 0x0004C78, 0x00000029 },	/* SWIRE_DP3_CH3_INPUT */
	{ 0x0004C7C, 0x00000028 },	/* SWIRE_DP3_CH4_INPUT */
	{ 0x000E0D4, 0x1F7DF0FF },	/* IRQ1_MASK_18 */
	{ REG_USER_MUTE, 0x00000000 },
	{ REG_POSTURE, 0x00000000 },
};

/* Audio serial port setup, as written by Linux for the HDA codec link. */
static const struct reg_val asp_config[] = {
	{ 0x0004804, 0x00000021 },	/* ASP1_CONTROL1 */
	{ 0x0004808, 0x20200200 },	/* ASP1_CONTROL2 */
	{ 0x000480C, 0x00000003 },	/* ASP1_CONTROL3 */
	{ 0x0004810, 0x03020100 },	/* ASP1_FRAME_CONTROL1 */
	{ 0x0004820, 0x00020100 },	/* ASP1_FRAME_CONTROL5 */
	{ 0x0004840, 0x00000018 },	/* ASP1_DATA_CONTROL5 */
	{ 0x0004830, 0x00000018 },	/* ASP1_DATA_CONTROL1 */
	{ REG_ASP1_ENABLES1, 0x00000000 },
	{ 0x0004C20, 0x00000018 },	/* ASP1TX1_INPUT */
	{ 0x0004C24, 0x00000019 },	/* ASP1TX2_INPUT */
	{ 0x0004C28, 0x00000020 },	/* ASP1TX3_INPUT */
	{ 0x0004C2C, 0x00000028 },	/* ASP1TX4_INPUT */
};

static int iic_fd = -1;

static int
sysctl_str(const char *name, char *buf, size_t len)
{
	size_t l = len - 1;

	if (sysctlbyname(name, buf, &l, NULL, 0) < 0)
		return (-1);
	buf[l] = '\0';
	return (0);
}

/* "ig4iic1" -> "dev.ig4iic.1.<leaf>": the unit is the trailing digits. */
static void
dev_oid(char *buf, size_t len, const char *dev, const char *leaf)
{
	size_t n = strlen(dev);

	while (n > 0 && dev[n - 1] >= '0' && dev[n - 1] <= '9')
		n--;
	snprintf(buf, len, "dev.%.*s.%s.%s", (int)n, dev, dev + n, leaf);
}

/*
 * Find the /dev node of driver drv (iic, gpioc) whose grandparent, the
 * controller, sits at ACPI path acpi.
 */
static void
find_dev(const char *drv, const char *acpi, char *path, size_t len)
{
	char name[64], bus[32], ctl[32], loc[128], want[64];

	snprintf(want, sizeof(want), "handle=%s", acpi);
	for (int i = 0; i < 64; i++) {
		snprintf(name, sizeof(name), "dev.%s.%d.%%parent", drv, i);
		if (sysctl_str(name, bus, sizeof(bus)) < 0)
			continue;
		dev_oid(name, sizeof(name), bus, "%parent");
		if (sysctl_str(name, ctl, sizeof(ctl)) < 0)
			continue;
		dev_oid(name, sizeof(name), ctl, "%location");
		if (sysctl_str(name, loc, sizeof(loc)) < 0)
			continue;
		if (strcmp(loc, want) == 0 ||
		    strncmp(loc, want, strlen(want)) == 0) {
			snprintf(path, len, "/dev/%s%d", drv, i);
			return;
		}
	}
	errx(1, "no %s(4) node under %s", drv, acpi);
}

/*
 * Hard reset of all four amps on their shared reset line, as Linux does at
 * probe: low for at least 1.1 ms, then high, then 2.2 ms for the control port.
 */
static void
hard_reset(void)
{
	char path[32];
	gpio_handle_t h;

	find_dev("gpioc", GPIO_ACPI_PATH, path, sizeof(path));
	if ((h = gpio_open_device(path)) == GPIO_INVALID_HANDLE)
		err(1, "%s", path);
	if (gpio_pin_output(h, GPIO_RESET_PIN) < 0 ||
	    gpio_pin_low(h, GPIO_RESET_PIN) < 0)
		err(1, "%s: pin %d low", path, GPIO_RESET_PIN);
	usleep(2200);
	if (gpio_pin_high(h, GPIO_RESET_PIN) < 0)
		err(1, "%s: pin %d high", path, GPIO_RESET_PIN);
	usleep(4400);
	gpio_close(h);
	printf("reset pulse on %s pin %d\n", path, GPIO_RESET_PIN);
}

/*
 * On FreeBSD (ig4), the first 32-bit word of every read is stale: it is
 * the word after the end of the previous read.  The following words are
 * correct.  So read two words from reg - 4 and keep the second one; this
 * also gives the right value on a bus without the problem.  DEVID (reg 0)
 * cannot be read this way.
 */
static int
rd32(uint8_t addr, uint32_t reg, uint32_t *val)
{
	uint32_t start = reg - 4;
	uint8_t w[4] = { start >> 24, start >> 16, start >> 8, start };
	uint8_t r[8];
	struct iic_msg msgs[2] = {
		{ addr << 1, IIC_M_WR, sizeof(w), w },
		{ addr << 1, IIC_M_RD, sizeof(r), r },
	};
	struct iic_rdwr_data d = { msgs, 2 };

	if (reg < 4)
		return (-1);
	if (ioctl(iic_fd, I2CRDWR, &d) < 0)
		return (-1);
	*val = (uint32_t)r[4] << 24 | r[5] << 16 | r[6] << 8 | r[7];
	return (0);
}

static int
wr32(uint8_t addr, uint32_t reg, uint32_t val)
{
	uint8_t w[8] = { reg >> 24, reg >> 16, reg >> 8, reg,
	    val >> 24, val >> 16, val >> 8, val };
	struct iic_msg msg = { addr << 1, IIC_M_WR, sizeof(w), w };
	struct iic_rdwr_data d = { &msg, 1 };

	if (ioctl(iic_fd, I2CRDWR, &d) < 0) {
		warn("0x%02x: write 0x%07x", addr, reg);
		return (-1);
	}
	return (0);
}

static int
wr_seq(uint8_t addr, const struct reg_val *seq, size_t n)
{
	for (size_t i = 0; i < n; i++)
		if (wr32(addr, seq[i].reg, seq[i].val) < 0)
			return (-1);
	return (0);
}

/* Poll reg until it equals want; step and timeout in microseconds. */
static int
poll_eq(uint8_t addr, uint32_t reg, uint32_t want, int step, int timeout,
    uint32_t *last)
{
	uint32_t val = 0;

	for (int t = 0; t <= timeout; t += step) {
		if (rd32(addr, reg, &val) == 0 && val == want) {
			if (last != NULL)
				*last = val;
			return (0);
		}
		usleep(step);
	}
	if (last != NULL)
		*last = val;
	return (-1);
}

static int
mbox(uint8_t addr, uint32_t cmd)
{
	uint32_t val;

	if (wr32(addr, REG_MBOX, cmd) < 0)
		return (-1);
	if (poll_eq(addr, REG_MBOX, 0, 250, 5000, &val) < 0) {
		warnx("0x%02x: mailbox 0x%08x not taken (0x%08x)", addr, cmd,
		    val);
		return (-1);
	}
	return (0);
}

/* Dummy accesses wake the amp from hibernation; the reads may fail. */
static void
wake(uint8_t addr)
{
	uint32_t val;

	(void)rd32(addr, REG_IRQ1_STATUS, &val);
	usleep(1000);
	(void)rd32(addr, REG_IRQ1_STATUS, &val);
	usleep(2200);
}

static int
wait_boot(uint8_t addr)
{
	uint32_t val;

	if (poll_eq(addr, REG_HALO_STATE, HALO_BOOT_DONE, 1000, 250000,
	    &val) < 0) {
		warnx("0x%02x: firmware boot timeout, HALO_STATE 0x%08x",
		    addr, val);
		return (-1);
	}
	return (0);
}

static void
info(uint8_t addr)
{
	uint32_t devid, revid, otpid, sec, fw, prot, ps, halo;

	wake(addr);
	if (rd32(addr, REG_HALO_STATE, &halo) < 0) {
		printf("0x%02x: no answer\n", addr);
		return;
	}
	wait_boot(addr);
	rd32(addr, REG_REVID, &revid);
	devid = 0;	/* not readable, see rd32() */
	rd32(addr, REG_OTPID, &otpid);
	rd32(addr, REG_RESTRICT_STS1, &sec);
	rd32(addr, REG_FW_VER, &fw);
	rd32(addr, REG_PROT_STS, &prot);
	rd32(addr, REG_ACTUAL_PS, &ps);
	(void)devid;
	printf("0x%02x: REVID 0x%02x OTP %u secured %s "
	    "fw %u.%u.%u PROT_STS 0x%x (%s) PS %u HALO %u\n",
	    addr, revid & 0xFF, otpid & 0xF,
	    sec ? "yes" : "no", (fw >> 16) & 0xFF, (fw >> 8) & 0xFF, fw & 0xFF,
	    prot, (prot & 1) ? "ROM, not patched" : "patched", ps, halo);
}

static uint32_t
volume_raw(double db)
{
	int q = (int)lround(db * 4);	/* 0.25 dB steps */

	if (q < -400)
		q = -400;
	if (q > 48)
		q = 48;
	return (((uint32_t)q & 0x3FF) << 6);
}

static int
play(uint8_t addr, int index, double db)
{
	uint32_t revid, ps;

	wake(addr);
	if (wait_boot(addr) < 0)
		return (-1);
	if (rd32(addr, REG_REVID, &revid) < 0 || (revid & 0xFF) != 0xB0) {
		warnx("0x%02x: unexpected REVID 0x%08x", addr, revid);
		return (-1);
	}
	if (mbox(addr, MBOX_PREVENT_HIBERNATE) < 0 ||
	    wr_seq(addr, patch, nitems(patch)) < 0 ||
	    wr32(addr, REG_USER_VOLUME, volume_raw(db)) < 0 ||
	    wr_seq(addr, asp_config, nitems(asp_config)) < 0 ||
	    mbox(addr, MBOX_PLAY) < 0)
		return (-1);
	if (poll_eq(addr, REG_ACTUAL_PS, 0, 500, 50000, &ps) < 0)
		warnx("0x%02x: PS0 not reached (PS %u)", addr, ps);
	/* ASP1 RX1 and RX2 in, one TX slot per amp */
	if (wr32(addr, REG_ASP1_ENABLES1, 0x00030000 | (1u << index)) < 0)
		return (-1);
	printf("0x%02x: playing, volume %.2f dB, PS %u\n", addr, db, ps);
	return (0);
}

/*
 * Phase 1b: DSP program (wmfw) and tuning (bin) download.
 * File formats and DSP memory map as used by the Linux cs_dsp loader.
 */
#define	REG_PM_CUR_STATE	0x2804308
#define	MBOX_SHUTDOWN		0x02000005
#define	MBOX_SYSTEM_RESET	0x02000007
#define	MBOX_AUDIO_REINIT	0x0B000003
#define	HALO_STATE_SHUTDOWN	1

#define	MEM_XM_PACKED		0x2000000
#define	MEM_XM_UNPACKED24	0x2800000
#define	MEM_YM_PACKED		0x2C00000
#define	MEM_YM_UNPACKED24	0x3400000
#define	MEM_PM_PACKED		0x3800000

#define	RT_ADSP2_XM		0x05
#define	RT_ADSP2_YM		0x06
#define	RT_HALO_PM_PACKED	0x10
#define	RT_HALO_XM_PACKED	0x11
#define	RT_HALO_YM_PACKED	0x12
#define	RT_ABSOLUTE		0xF0

#define	RAW_CHUNK		4096	/* bytes per I2C write */
#define	MAX_ALGS		64
#define	ALG_LIST_END		0x00BEDEAD

struct alg {
	uint32_t id, ver, xm_base, ym_base;
};

static bool dry_run, verbose, write_pm = true;

static uint32_t
le32(const uint8_t *p)
{
	return (p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24);
}

static uint16_t
le16(const uint8_t *p)
{
	return (p[0] | p[1] << 8);
}

static uint32_t
be32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]);
}

static uint8_t *
load_file(const char *path, size_t *len)
{
	FILE *f;
	uint8_t *buf;
	long n;

	if ((f = fopen(path, "r")) == NULL)
		err(1, "%s", path);
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	rewind(f);
	if (n <= 0 || (buf = malloc(n)) == NULL ||
	    fread(buf, 1, n, f) != (size_t)n)
		errx(1, "%s: read failed", path);
	fclose(f);
	*len = n;
	return (buf);
}

/* DSP region offset to register address (Halo core). */
static uint32_t
region_to_reg(int type, uint32_t off)
{
	switch (type) {
	case RT_ADSP2_XM:
		return (MEM_XM_UNPACKED24 + off * 4);
	case RT_ADSP2_YM:
		return (MEM_YM_UNPACKED24 + off * 4);
	case RT_HALO_XM_PACKED:
		return ((MEM_XM_PACKED + off * 3) & ~3u);
	case RT_HALO_YM_PACKED:
		return ((MEM_YM_PACKED + off * 3) & ~3u);
	case RT_HALO_PM_PACKED:
		return (MEM_PM_PACKED + off * 5);
	}
	return (0);
}

/* Raw block write, bytes as in the file, split like Linux regmap does. */
static int
wr_raw(uint8_t addr, uint32_t reg, const uint8_t *data, size_t len)
{
	static uint8_t buf[4 + RAW_CHUNK];

	if (len % 4 != 0) {
		warnx("0x%02x: 0x%07x: length %zu not a word multiple", addr,
		    reg, len);
		return (-1);
	}
	while (len > 0) {
		size_t n = MIN(len, RAW_CHUNK);
		struct iic_msg msg = { addr << 1, IIC_M_WR, 4 + n, buf };
		struct iic_rdwr_data d = { &msg, 1 };

		if (verbose || dry_run)
			printf("  0x%02x W %08x block %zu words, first %08x\n",
			    addr, reg, n / 4, be32(data));
		if (!dry_run) {
			buf[0] = reg >> 24; buf[1] = reg >> 16;
			buf[2] = reg >> 8; buf[3] = reg;
			memcpy(buf + 4, data, n);
			if (ioctl(iic_fd, I2CRDWR, &d) < 0) {
				warn("0x%02x: block write 0x%07x", addr, reg);
				return (-1);
			}
		}
		reg += n;
		data += n;
		len -= n;
	}
	return (0);
}

/* Block read of n words at reg, with the stale-first-word workaround. */
static int
rd_block(uint8_t addr, uint32_t reg, uint32_t *out, size_t n)
{
	uint32_t start = reg - 4;
	uint8_t w[4] = { start >> 24, start >> 16, start >> 8, start };
	uint8_t *r = malloc(4 * (n + 1));
	struct iic_msg msgs[2] = {
		{ addr << 1, IIC_M_WR, sizeof(w), w },
		{ addr << 1, IIC_M_RD, 4 * (n + 1), r },
	};
	struct iic_rdwr_data d = { msgs, 2 };
	int rc = 0;

	if (r == NULL || ioctl(iic_fd, I2CRDWR, &d) < 0)
		rc = -1;
	else
		for (size_t i = 0; i < n; i++)
			out[i] = be32(r + 4 * (i + 1));
	free(r);
	return (rc);
}

static int
write_wmfw(uint8_t addr, const uint8_t *fw, size_t len)
{
	size_t pos;
	int n = 0;

	if (len < 40 || memcmp(fw, "WMFW", 4) != 0 || fw[10] != 4) {
		warnx("wmfw: bad header (magic, or core %d not Halo)",
		    len > 10 ? fw[10] : -1);
		return (-1);
	}
	/* header 12 bytes, sizes 16, footer 12: header len must say 40 */
	if ((pos = le32(fw + 4)) != 40) {
		warnx("wmfw: header length %zu, expected 40", pos);
		return (-1);
	}
	while (pos + 8 <= len) {
		uint32_t off = le32(fw + pos) & 0xFFFFFF;
		int type = fw[pos + 3];
		uint32_t rlen = le32(fw + pos + 4), reg = 0;

		if (rlen > len - pos - 8) {
			warnx("wmfw: region %d overflows the file", n);
			return (-1);
		}
		/*
		 * The Linux I2C trace on this laptop has no write to program
		 * memory (0x3800000), although the file has a PM region;
		 * it is still required here (see the plan), -s skips it.
		 */
		if (type == RT_ABSOLUTE)
			reg = off;
		else if (type != RT_HALO_PM_PACKED || write_pm)
			reg = region_to_reg(type, off);
		if (reg != 0 && wr_raw(addr, reg, fw + pos + 8, rlen) < 0)
			return (-1);
		pos += 8 + rlen;
		n++;
	}
	printf("0x%02x: wmfw: %d regions\n", addr, n);
	return (0);
}

static int
read_algs(uint8_t addr, struct alg *algs, int *nalgs)
{
	uint32_t hdr[10], end, list[MAX_ALGS * 6];
	int n;

	if (rd_block(addr, MEM_XM_UNPACKED24, hdr, 10) < 0)
		return (-1);
	n = hdr[9];
	if (n <= 0 || n > MAX_ALGS) {
		warnx("0x%02x: %d algorithms", addr, n);
		return (-1);
	}
	if (rd32(addr, MEM_XM_UNPACKED24 + 40 + n * 24, &end) < 0 ||
	    end != ALG_LIST_END)
		warnx("0x%02x: algorithm list end 0x%08x", addr, end);
	if (rd_block(addr, MEM_XM_UNPACKED24 + 40, list, n * 6) < 0)
		return (-1);
	/*
	 * Header: core_id, block_rev, vendor_id, id, ver, xm_base, xm_size,
	 * ym_base, ym_size, n_algs.  The firmware id itself also owns XM/YM
	 * regions (global coefficients), like each algorithm.
	 */
	algs[0].id = hdr[3];
	algs[0].ver = hdr[4];
	algs[0].xm_base = hdr[5];
	algs[0].ym_base = hdr[7];
	for (int i = 0; i < n; i++) {
		algs[i + 1].id = list[6 * i];
		algs[i + 1].ver = list[6 * i + 1];
		algs[i + 1].xm_base = list[6 * i + 2];
		algs[i + 1].ym_base = list[6 * i + 4];
	}
	*nalgs = n + 1;
	printf("0x%02x: firmware 0x%06x v%u.%u.%u, %d algorithms\n", addr,
	    hdr[3], (hdr[4] >> 16) & 0xFF, (hdr[4] >> 8) & 0xFF, hdr[4] & 0xFF,
	    n);
	return (0);
}

static int
write_bin(uint8_t addr, const uint8_t *fw, size_t len, const struct alg *algs,
    int nalgs)
{
	size_t pos;
	int n = 0, missing = 0;

	if (len < 16 || memcmp(fw, "WMDR", 4) != 0) {
		warnx("bin: bad magic");
		return (-1);
	}
	pos = le32(fw + 4);
	while (pos + 20 <= len) {
		uint32_t off = le16(fw + pos), id = le32(fw + pos + 4);
		int type = le16(fw + pos + 2);
		uint32_t blen = le32(fw + pos + 16), reg = 0;

		if (blen > len - pos - 20) {
			warnx("bin: block %d overflows the file", n);
			return (-1);
		}
		if (type == 0xF405 || type == 0xF406 || type == 0xF411 ||
		    type == 0xF412) {
			off = le32(fw + pos + 12);
			type &= 0xFF;
		}
		switch (type) {
		case RT_ABSOLUTE << 8:
			reg = off;
			break;
		case RT_ADSP2_XM:
		case RT_ADSP2_YM:
		case RT_HALO_XM_PACKED:
		case RT_HALO_YM_PACKED: {
			int i;
			bool xm = type == RT_ADSP2_XM ||
			    type == RT_HALO_XM_PACKED;

			for (i = 0; i < nalgs && algs[i].id != id; i++)
				;
			if (i == nalgs) {
				warnx("0x%02x: bin block %d: no algorithm "
				    "0x%x", addr, n, id);
				missing++;
				break;
			}
			reg = region_to_reg(type,
			    xm ? algs[i].xm_base : algs[i].ym_base) + off;
			break;
		}
		default:	/* name, info, metadata */
			break;
		}
		if (reg != 0 && wr_raw(addr, reg, fw + pos + 20, blen) < 0)
			return (-1);
		pos += (blen + 20 + 3) & ~3u;
		n++;
	}
	printf("0x%02x: bin: %d blocks, %d without algorithm\n", addr, n,
	    missing);
	return (0);
}

static int
system_reset(uint8_t addr)
{
	/* Linux B0 sequence: clear HALO_STATE, then the reset mailbox. */
	if (wr32(addr, REG_HALO_STATE, 0) < 0 ||
	    wr32(addr, REG_MBOX, MBOX_SYSTEM_RESET) < 0)
		return (-1);
	usleep(2200);
	return (wait_boot(addr));
}

static int
load(uint8_t addr, int index, const char *dir)
{
	char path[PATH_MAX];
	uint8_t *wmfw, *bin;
	size_t wlen, blen;
	struct alg algs[MAX_ALGS + 1];
	uint32_t prot, val;
	int nalgs, rc = -1;

	snprintf(path, sizeof(path), "%s/cs35l54-b0-dsp1-misc-103c8d01.wmfw",
	    dir);
	wmfw = load_file(path, &wlen);
	snprintf(path, sizeof(path),
	    "%s/cs35l54-b0-dsp1-misc-103c8d01-amp%d.bin", dir, index + 1);
	bin = load_file(path, &blen);
	if (dry_run) {
		rc = write_wmfw(addr, wmfw, wlen);
		goto out;
	}
	wake(addr);
	if (wait_boot(addr) < 0 || mbox(addr, MBOX_PREVENT_HIBERNATE) < 0 ||
	    system_reset(addr) < 0 ||
	    wr_seq(addr, patch, nitems(patch)) < 0 ||
	    wr_seq(addr, asp_config, nitems(asp_config)) < 0 ||
	    rd32(addr, REG_PROT_STS, &prot) < 0)
		goto out;
	if (prot & 1) {
		if (mbox(addr, MBOX_SHUTDOWN) < 0)
			goto out;
		if (poll_eq(addr, REG_PM_CUR_STATE, HALO_STATE_SHUTDOWN, 1000,
		    250000, &val) < 0) {
			warnx("0x%02x: PM_CUR_STATE %u after shutdown", addr,
			    val);
			goto out;
		}
	}
	if (write_wmfw(addr, wmfw, wlen) < 0 ||
	    read_algs(addr, algs, &nalgs) < 0 ||
	    write_bin(addr, bin, blen, algs, nalgs) < 0 ||
	    system_reset(addr) < 0 ||
	    mbox(addr, MBOX_PREVENT_HIBERNATE) < 0 ||
	    wr_seq(addr, patch, nitems(patch)) < 0 ||
	    wr_seq(addr, asp_config, nitems(asp_config)) < 0 ||
	    mbox(addr, MBOX_AUDIO_REINIT) < 0)
		goto out;
	rd32(addr, REG_PROT_STS, &prot);
	rd32(addr, REG_FW_VER, &val);
	printf("0x%02x: loaded, PROT_STS 0x%x, fw %u.%u.%u\n", addr, prot,
	    (val >> 16) & 0xFF, (val >> 8) & 0xFF, val & 0xFF);
	rc = 0;
out:
	free(wmfw);
	free(bin);
	return (rc);
}

static int
stop(uint8_t addr)
{
	wake(addr);
	if (mbox(addr, MBOX_PAUSE) < 0)
		return (-1);
	wr32(addr, REG_ASP1_ENABLES1, 0);
	if (mbox(addr, MBOX_ALLOW_HIBERNATE) < 0)
		return (-1);
	printf("0x%02x: stopped\n", addr);
	return (0);
}

static void
tone(double hz, double secs, double dbfs)
{
	double amp = 32767 * pow(10, dbfs / 20);
	const char *dsp = getenv("DSP") != NULL ? getenv("DSP") : DSP_DEV;
	int fd, fmt = AFMT_S16_LE, ch = 2, rate = 48000;
	int16_t buf[2 * 480];
	long frames = (long)(secs * rate), done = 0;

	if ((fd = open(dsp, O_WRONLY)) < 0)
		err(1, "%s", dsp);
	if (ioctl(fd, SNDCTL_DSP_SETFMT, &fmt) < 0 ||
	    ioctl(fd, SNDCTL_DSP_CHANNELS, &ch) < 0 ||
	    ioctl(fd, SNDCTL_DSP_SPEED, &rate) < 0)
		err(1, "%s: setup", dsp);
	while (done < frames) {
		for (int i = 0; i < 480; i++, done++) {
			int16_t s = (int16_t)(amp *
			    sin(2 * M_PI * hz * done / rate));
			buf[2 * i] = buf[2 * i + 1] = s;
		}
		if (write(fd, buf, sizeof(buf)) < 0)
			err(1, "%s: write", dsp);
	}
	close(fd);
}

static void
usage(void)
{
	fprintf(stderr, "usage: cs35l54_tool reset | info | load [-nsv] DIR | "
	    "play [-v dB] | "
	    "stop | tone [Hz [seconds [dBFS]]] | read REG... | "
	    "write ADDR REG VAL\n");
	exit(1);
}

int
main(int argc, char **argv)
{
	char iic_path[32];
	double db = -20.0;
	int rc = 0;

	if (argc < 2)
		usage();
	if (strcmp(argv[1], "tone") == 0) {
		tone(argc > 2 ? atof(argv[2]) : 440.0,
		    argc > 3 ? atof(argv[3]) : 3.0,
		    argc > 4 ? atof(argv[4]) : -12.0);
		return (0);
	}
	if (strcmp(argv[1], "reset") == 0) {
		hard_reset();
		return (0);
	}
	if (strcmp(argv[1], "load") == 0) {
		int ch;

		optind = 2;
		while ((ch = getopt(argc, argv, "nsv")) != -1) {
			if (ch == 'n')
				dry_run = true;
			else if (ch == 's')
				write_pm = false;
			else if (ch == 'v')
				verbose = true;
			else
				usage();
		}
		if (optind != argc - 1)
			usage();
		if (dry_run) {
			for (int i = 0; i < AMP_COUNT; i++)
				rc |= load(AMP_FIRST + i, i, argv[optind]);
			return (rc != 0);
		}
	}
	if (strcmp(argv[1], "play") == 0 && argc == 4 &&
	    strcmp(argv[2], "-v") == 0)
		db = atof(argv[3]);
	find_dev("iic", IIC_ACPI_PATH, iic_path, sizeof(iic_path));
	if ((iic_fd = open(iic_path, O_RDWR)) < 0)
		err(1, "%s", iic_path);
	if (strcmp(argv[1], "read") == 0 && argc >= 3) {
		for (int i = 0; i < AMP_COUNT; i++) {
			printf("0x%02x:", AMP_FIRST + i);
			for (int a = 2; a < argc; a++) {
				uint32_t reg = strtoul(argv[a], NULL, 16), v;

				if (rd32(AMP_FIRST + i, reg, &v) < 0)
					printf(" %07x=error", reg);
				else
					printf(" %07x=%08x", reg, v);
			}
			printf("\n");
		}
		return (0);
	}
	if (strcmp(argv[1], "write") == 0 && argc == 5) {
		uint8_t addr = strtoul(argv[2], NULL, 16);

		return (wr32(addr, strtoul(argv[3], NULL, 16),
		    strtoul(argv[4], NULL, 16)) < 0);
	}
	for (int i = 0; i < AMP_COUNT; i++) {
		uint8_t addr = AMP_FIRST + i;

		if (strcmp(argv[1], "info") == 0)
			info(addr);
		else if (strcmp(argv[1], "load") == 0)
			rc |= load(addr, i, argv[optind]);
		else if (strcmp(argv[1], "play") == 0)
			rc |= play(addr, i, db);
		else if (strcmp(argv[1], "stop") == 0)
			rc |= stop(addr);
		else
			usage();
	}
	close(iic_fd);
	return (rc != 0);
}
