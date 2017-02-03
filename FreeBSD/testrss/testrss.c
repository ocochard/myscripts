/* Discovering Toeplitz hash algorithm */
/* 99.999 % of the code here is just a copy/past of FreeBSD RSS/toeplitz code */

#include <stdio.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <strings.h>

#include <sys/param.h>
#include <sys/mbuf.h>

/* for software rss hash support */
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>


/* ====== src/sys/net/rss_config.c */
/*
 * Maximum key size used throughout.  It's OK for hardware to use only the
 * first 16 bytes, which is all that's required for IPv4.
 */
#define RSS_KEYSIZE 40

/*
 * RSS secret key, intended to prevent attacks on load-balancing.  Its
 * effectiveness may be limited by algorithm choice and available entropy
 * during the boot.
 *
 * XXXRW: And that we don't randomize it yet!
 *
 * This is the default Microsoft RSS specification key which is also
 * the Chelsio T5 firmware default key.
 */
static uint8_t rss_key[RSS_KEYSIZE] = {
    0x6d, 0x5a, 0x56, 0xda, 0x25, 0x5b, 0x0e, 0xc2,
    0x41, 0x67, 0x25, 0x3d, 0x43, 0xa3, 0x8f, 0xb0,
    0xd0, 0xca, 0x2b, 0xcb, 0xae, 0x7b, 0x30, 0xb4,
    0x77, 0xcb, 0x2d, 0xa3, 0x80, 0x30, 0xf2, 0x0c,
    0x6a, 0x42, 0xb7, 0x3b, 0xbe, 0xac, 0x01, 0xfa,
};

/* ====== src/sys/net/toeplitz.c ======= */

uint32_t
toeplitz_hash(u_int keylen, const uint8_t *key, u_int datalen,
    const uint8_t *data)
{
    uint32_t hash = 0, v;
    u_int i, b;

    /* XXXRW: Perhaps an assertion about key length vs. data length? */

    v = (key[0]<<24) + (key[1]<<16) + (key[2] <<8) + key[3];
    for (i = 0; i < datalen; i++) {
        for (b = 0; b < 8; b++) {
            if (data[i] & (1<<(7-b)))
                hash ^= v;
            v <<= 1;
            if ((i + 4) < RSS_KEYSIZE &&
                (key[i+4] & (1<<(7-b))))
                v |= 1;
        }
    }
    return (hash);
}

/* ======= src/sys/netinet/in_rss.c ========= */

/*
 * Hash an IPv4 2-tuple.
 */
uint32_t
rss_hash_ip4_2tuple(struct in_addr src, struct in_addr dst)
{
        uint8_t data[sizeof(src) + sizeof(dst)];
        u_int datalen;

        datalen = 0;
        bcopy(&src, &data[datalen], sizeof(src));
        datalen += sizeof(src);
        bcopy(&dst, &data[datalen], sizeof(dst));
        datalen += sizeof(dst);
        return toeplitz_hash(sizeof(rss_key), rss_key, datalen, data);
}

/*
 * Hash an IPv4 4-tuple.
 */
uint32_t
rss_hash_ip4_4tuple(struct in_addr src, u_short srcport, struct in_addr dst,
    u_short dstport)
{
        uint8_t data[sizeof(src) + sizeof(dst) + sizeof(srcport) +
            sizeof(dstport)];
        u_int datalen;

        datalen = 0;
        bcopy(&src, &data[datalen], sizeof(src));
        datalen += sizeof(src);
        bcopy(&dst, &data[datalen], sizeof(dst));
        datalen += sizeof(dst);
        bcopy(&srcport, &data[datalen], sizeof(srcport));
        datalen += sizeof(srcport);
        bcopy(&dstport, &data[datalen], sizeof(dstport));
        datalen += sizeof(dstport);
        return toeplitz_hash(sizeof(rss_key), rss_key, datalen, data);
}


/* Here we add the MS official value to check */
int main ()
{
	
	const char *dst_addrt[5] = {"161.142.100.80", "65.69.140.83", "12.22.207.184", "209.142.163.6", "202.188.127.2"};
	const char *src_addrt[5] = {"66.9.149.187", "199.92.111.2", "24.19.198.95", "38.27.205.30", "153.39.163.191"};
	const u_short dst_portt[5] = { 1766, 4739, 38024, 2217, 1303};
	const u_short src_portt[5] = { 2794, 14230, 12898, 48228, 44251};
	const uint32_t two[5] = { 0x323e8fc2, 0xd718262a, 0xd2d0a5de, 0x82989176, 0x5d1809c5 };
	const uint32_t four[5] = { 0x51ccc178, 0xc626b0ea, 0x5c2b394a, 0xafc7327f, 0x10e828a2 };
	struct in_addr src_addr; /* uint32_t */
	struct in_addr dst_addr; /* uint32_t */
	printf("Verifying the RSS Hash Calculation\n");
	printf("https://msdn.microsoft.com/en-us/windows/hardware/drivers/network/verifying-the-rss-hash-calculation\n");
	printf("Dest IP:port\t\tSource IP:port\t\t2tuple MS ref\t2tuple fbsd\t4tuple MS ref\t4tuple fbsd\n");
	for (u_int i=0; i < 5 ;i++) {
		inet_aton(src_addrt[i], &src_addr);
		inet_aton(dst_addrt[i], &dst_addr);
		printf("%s:%d\t%s:%d\t0x%08x\t0x%08x\t0x%08x\t0x%08x\n", dst_addrt[i], dst_portt[i], src_addrt[i], src_portt[i], two[i], four[i],
		rss_hash_ip4_2tuple(src_addr, dst_addr), rss_hash_ip4_4tuple(src_addr, src_portt[i], dst_addr, dst_portt[i]));
	}
	return 0;
}
