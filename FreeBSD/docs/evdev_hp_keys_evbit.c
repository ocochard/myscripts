/* evbit: print the name of each /dev/input/event* and whether it supports two keys. */
#include <sys/ioctl.h>
#include <dev/evdev/input.h>
#include <fcntl.h>
#include <glob.h>
#include <stdio.h>
#include <unistd.h>
int
main(void)
{
	unsigned char bits[KEY_MAX / 8 + 1];
	char name[128];
	glob_t g;
	size_t i;
	int fd;

	glob("/dev/input/event*", 0, NULL, &g);
	for (i = 0; i < g.gl_pathc; i++) {
		if ((fd = open(g.gl_pathv[i], O_RDONLY)) < 0)
			continue;
		name[0] = '\0';
		ioctl(fd, EVIOCGNAME(sizeof(name)), name);
		if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(bits)), bits) >= 0)
			printf("%s %-40s MICMUTE %d PROG1 %d\n", g.gl_pathv[i], name,
			    (bits[KEY_MICMUTE / 8] >> (KEY_MICMUTE % 8)) & 1,
			    (bits[KEY_PROG1 / 8] >> (KEY_PROG1 % 8)) & 1);
		close(fd);
	}
	return (0);
}
