/*
 * vtblank - paint the console framebuffer black from the command line.
 *
 * vt(4) has no working screen saver: CONS_BLANKTIME (what "vidcontrol -t"
 * sends) is a stub returning 0 in sys/dev/vt/vt_core.c, and the syscons
 * *_saver.ko modules do not attach to vt.  The one blanking path vt does
 * implement is the FBIO_BLANK ioctl, which sys/dev/vt/hw/fb/vt_fb.c turns
 * into vd_blank(vd, TC_BLACK) - a direct fill of the framebuffer.  No
 * userland tool in base issues it, hence this program.
 *
 * Caveats, both inherent to vt_fb_blank():
 *   - The mode argument (V_DISPLAY_ON and friends) is ignored: vt always
 *     fills with black.  There is no "unblank" ioctl; the screen comes back
 *     on the next repaint (any console output, or a vty switch:
 *     "vidcontrol -s 1").
 *   - This paints pixels only.  It does not signal DPMS, so the monitor
 *     stays powered on.  vt exposes no DPMS control at all.
 */

#include <sys/fbio.h>
#include <sys/ioctl.h>

#include <err.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <unistd.h>

#define DEFAULT_DEVICE	"/dev/console"

static void
usage(void)
{
	fprintf(stderr,
	    "usage: vtblank [-f device] [on | blank | standby | suspend]\n"
	    "\n"
	    "  -f device  console/tty to act on (default: stdin if it is a\n"
	    "             tty, else " DEFAULT_DEVICE ")\n"
	    "\n"
	    "The mode defaults to \"blank\" and is ignored by vt(4), which\n"
	    "always fills the framebuffer with black.\n");
	exit(EX_USAGE);
}

static int
parse_mode(const char *name)
{
	if (strcmp(name, "on") == 0)
		return (V_DISPLAY_ON);
	if (strcmp(name, "blank") == 0)
		return (V_DISPLAY_BLANK);
	if (strcmp(name, "standby") == 0)
		return (V_DISPLAY_STAND_BY);
	if (strcmp(name, "suspend") == 0)
		return (V_DISPLAY_SUSPEND);
	return (-1);
}

int
main(int argc, char *argv[])
{
	const char *device = NULL;
	int ch, fd, mode;

	while ((ch = getopt(argc, argv, "f:")) != -1) {
		switch (ch) {
		case 'f':
			device = optarg;
			break;
		default:
			usage();
			/* NOTREACHED */
		}
	}
	argc -= optind;
	argv += optind;

	if (argc > 1)
		usage();

	mode = V_DISPLAY_BLANK;
	if (argc == 1 && (mode = parse_mode(argv[0])) == -1)
		errx(1, "unknown mode: %s", argv[0]);

	/*
	 * Like vidcontrol(1), act on the controlling terminal when there is
	 * one, so "vtblank" from a vty just works.  Fall back to the console
	 * device when stdin is redirected (cron, a pipe, ...).
	 */
	if (device == NULL) {
		if (isatty(STDIN_FILENO)) {
			fd = STDIN_FILENO;
			device = "stdin";
		} else {
			device = DEFAULT_DEVICE;
			fd = -1;
		}
	} else
		fd = -1;

	if (fd == -1 && (fd = open(device, O_RDONLY)) == -1)
		err(1, "open %s", device);

	if (ioctl(fd, FBIO_BLANK, &mode) == -1)
		err(1, "FBIO_BLANK on %s", device);

	return (0);
}
