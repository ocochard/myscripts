/* Discovering Toeplitz hash algorithm */
/* 99.999 % of the code here is just a copy/past of FreeBSD RSS/toeplitz code */

#include <stdio.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <strings.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>

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
/* The key is 40 bytes (320 bits) long for the Toeplitz hash on IPv6 and 16 bytes (128 bits) for IPv4 packets */
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

/* Toeplitz official MS pseudo code
*
* ComputeHash(input[], n)
*   result = 0
*   For each bit b in input[] from left to right {
*       if (b == 1) result ^= (left-most 32 bits of K)
*       shift K left 1 bit position
*   }
*   return result
*/


/* ====== code from src/sys/net/toeplitz.c ======= */

uint32_t
toeplitz_hash(u_int keylen, const uint8_t *key, u_int datalen,
    const uint8_t *data)
{
    uint32_t hash = 0, v;
    u_int i, b;

    /* XXXRW: Perhaps an assertion about key length vs. data length? */

    v = (key[0]<<24) + (key[1]<<16) + (key[2] <<8) + key[3];
    for (i = 0; i < datalen; i++) {
	//printf("key loop[%d]: %08x\n",i, v);
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

/* ===== code from  http://read.pudn.com/downloads163/sourcecode/internet/tcp_ip/743929/toeplitz_hash.c__.htm */
/* Give same result as FreeBSD */
uint32_t toeplitz_hash3(u_int keylen, const uint8_t *key, u_int datalen, uint8_t *data)
{
    uint32_t hash=0;
    uint8_t bdata=0;
    uint32_t keysmall = 0;
    u_int i, b;

    keysmall = ntohl(*(uint32_t *)key);

    for (i=0; i < datalen; i++){
        bdata = data[i];
        for (b=0; b < 8; b++){
            if((bdata << b)& (0x80))
                hash ^= keysmall;
            keysmall =  (keysmall <<1) | ((key[i+4] >> (7-b)) & 0x1);
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

/* http://revoman.tistory.com/entry/Implementation-of-htonll-ntohll-uint64t-byte-ordering */
uint64_t ntohll(uint64_t host_longlong)
{
    int x = 1;

    /* little endian */
    if(*(char *)&x == 1)
        return ((((uint64_t)ntohl(host_longlong)) << 32) + ntohl(host_longlong >> 32));

    /* big endian */
    else
        return host_longlong;

}
/* Here we add the MS official value to check */
int validate ()
{
	const char *dst_addrt[5] = {"161.142.100.80", "65.69.140.83", "12.22.207.184", "209.142.163.6", "202.188.127.2"};
	const char *src_addrt[5] = {"66.9.149.187", "199.92.111.2", "24.19.198.95", "38.27.205.30", "153.39.163.191"};
	const u_short dst_portt[5] = { 1766, 4739, 38024, 2217, 1303};
	const u_short src_portt[5] = { 2794, 14230, 12898, 48228, 44251};
	const uint32_t two[5] = { 0x323e8fc2, 0xd718262a, 0xd2d0a5de, 0x82989176, 0x5d1809c5 };
	const uint32_t four[5] = { 0x51ccc178, 0xc626b0ea, 0x5c2b394a, 0xafc7327f, 0x10e828a2 };
	struct in_addr src_addr; /* uint32_t */
	struct in_addr dst_addr; /* uint32_t */
	printf("No argument given SRC_IP:SRC_PORT DST_IP:DST_PORT");
	printf("Verifying the RSS Hash Calculation\n");
	printf("https://msdn.microsoft.com/en-us/windows/hardware/drivers/network/verifying-the-rss-hash-calculation\n");
	printf("key:\n");
	for (u_int i=0; i < RSS_KEYSIZE; i=i+8) {
		printf("%lx\n",ntohll(*(uint64_t *)(rss_key + i)));
	}
	printf("\nMS websibe dispaly table with destination IP first, but because all functions use source first, I've swapped them\n");
	printf("Source IP:port\t\tDest IP:port\t\t2tuple MS ref\t2tuple fbsd\t4tuple MS ref\t4tuple fbsd\n");
	for (u_int i=0; i < 5 ;i++) {
		inet_aton(src_addrt[i], &src_addr);
		inet_aton(dst_addrt[i], &dst_addr);
		/* printf("%s(%08x):%d(%02x)\t%s(%08x):%d(%02x)\t%08x\t%08x\t%08x\t%08x\n", src_addrt[i], ntohl(src_addr.s_addr),
		src_portt[i], ntohs(src_portt[i]) , dst_addrt[i], ntohl(dst_addr.s_addr), dst_portt[i], ntohs(dst_portt[i]), two[i],
		rss_hash_ip4_2tuple(src_addr, dst_addr), four[i], rss_hash_ip4_4tuple(src_addr, src_portt[i], dst_addr, dst_portt[i])); */
		printf("%s:%d\t%s:%d\t%08x\t%08x\t%08x\t%08x\n", src_addrt[i], src_portt[i], dst_addrt[i], dst_portt[i], two[i],
                rss_hash_ip4_2tuple(src_addr, dst_addr), four[i], rss_hash_ip4_4tuple(src_addr, htons(src_portt[i]), dst_addr, htons(dst_portt[i])));
	}
	exit (0);
}

int
main(int argc, char *argv[])
{
	struct in_addr src, dst;
	uint16_t srcport, dstport;
	uint32_t hash;
	int val;
	char *p;
	static short rss_mask = 0x3;

	if (argc != 3)
		validate();

	printf("[%s] [%s]\n", argv[1], argv[2]);

	p = strchr(argv[1], ':');
	assert(p != NULL);
	*p = '\0';
	inet_aton(argv[1], &src);
	val = atoi(p + 1);
	assert(val >= 0 && val <= 65535);
	srcport = (uint16_t)val;

	p = strchr(argv[2], ':');
	assert(p != NULL);
	*p = '\0';
	inet_aton(argv[2], &dst);
	val = atoi(p + 1);
	assert(val >= 0 && val <= 65535);
	dstport = (uint16_t)val;
	hash=rss_hash_ip4_4tuple(src, htons(srcport), dst, htons(dstport));
	printf("hash/queue: %08x/%u\n", hash, hash & rss_mask);

	return (0);
}
