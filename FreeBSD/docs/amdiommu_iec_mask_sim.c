#include <stdio.h>
#include <strings.h>
#define min(a, b) ((a) < (b) ? (a) : (b))
static void
run(unsigned start, unsigned cnt, unsigned mhmv)
{
	unsigned c, l;

	printf("start %u cnt %u mhmv %u:", start, cnt, mhmv);
	for (; cnt > 0; cnt -= c, start += c) {
		l = min(ffs(start | cnt) - 1, mhmv);
		c = 1 << l;
		printf(" [%u+%u im%u%s]", start, c, l, start % c ? " MISALIGNED" : "");
	}
	printf("\n");
}
int
main(void)
{
	run(54, 8, 15); run(54, 8, 1); run(48, 8, 15); run(48, 8, 1);
	run(32, 32, 0); run(32, 32, 2); run(7, 1, 0);
	return (0);
}
