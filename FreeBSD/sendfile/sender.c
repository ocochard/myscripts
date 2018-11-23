// vim: tabstop=8 shiftwidth=8 columns=80 smarttab cindent noexpandtab
/* sendfile(2) regression test */

#include <fcntl.h> /* open */
#include <stdio.h> /* fprintf */
#include <stdlib.h> /* exit */
#include <string.h> /* atoi */
#include <unistd.h> /* getopt, setuid, getuid, close */
#include <sysexits.h> /* EX_USAGE */
#include <sys/types.h> /* needed by sendfile */
#include <sys/socket.h> /* it's a network software */
#include <sys/uio.h>  /* needed by sendfile */
#include <netinet/in.h>
#include <netdb.h> /* getaddrinfo */
#include <errno.h> /* sendfile uses errno */

static void usage(void){
	fprintf(stderr,"Usage:\n");
	fprintf(stderr," -f <string> : filename\n");
	fprintf(stderr," -h <string> : hostname or IP address\n");
	fprintf(stderr," -p <int>    : port number\n");
	fprintf(stderr," -o <int>    : offset\n");
	fprintf(stderr," -n <int>    : nbytes\n");
	fprintf(stderr," -r <int>    : readahead pages\n");
	fprintf(stderr," -c          : set SF_NOCACHE flag\n");
	fprintf(stderr," -u          : set SF_USER_READAHEAD flag\n");
	fprintf(stderr," -s          : set SF_SYNC flag\n");
	fprintf(stderr," -d          : set SF_NODISKIO flag\n");
	exit(EX_USAGE);
}

int main(int argc, char *argv[]){

	unsigned long port=0; /* UDP destination port */
	char *dummy; /* mandatory for strtoul but not used */
	char host[256]={0},ports[256]={0},file[256]={0};
	off_t offset=0;
	size_t nbytes=0;
	unsigned int readahead=16;
	uint8_t flags=0;
	for (;;) {
		int opt = getopt(argc, argv, "cusdf:h:n:o:p:r:");
		if (opt == -1) {
			break; /* exit for loop when reach end of argv */
		}
		switch (opt) {
		case 'c':
			flags |= SF_NOCACHE;
			break;
		case 'd':
			flags |=  SF_NODISKIO;
			break;
		case 'f':
			strcpy(file, optarg );
			break;
		case 'h':
			strcpy(host, optarg );
			break;
		case 'n':
			/* convert the string optarg to unsigned_long */
			nbytes = strtoul(optarg, &dummy, 10);
			break;
		case 'o':
			/* convert the string optarg to unsigned_long */
			offset = strtoul(optarg, &dummy, 10);
			break;
		case 'p':
			strcpy(ports, optarg );
			/* convert the string "port" to unsigned_long */
			port = strtoul(ports, &dummy, 10);
			break;
		case 'r':
			/* convert the string optarg to unsigned_long */
			readahead = strtoul(optarg, &dummy, 10);
			break;
		case 's':
			flags |=  SF_SYNC;
			break;
		case 'u':
			flags |=  SF_USER_READAHEAD;
			break;
		default:
			/* Unexpected option */
			usage();
			return 1;
		}
	}

	/* Checking user input */
	if (port < 1 || port > 65535 || *dummy != '\0') {
		fprintf(stderr, "Invalid port number: %lu\n",port);
		usage();
	}
	int fd = open(file, O_RDONLY);
	if(fd < 0) {
		fprintf(stderr, "open file error: %s\n", strerror(errno));
		usage();
	}

	if (host[0] == 0) {
		fprintf(stderr, "Missing hostname\n");
		usage();
	}
	const char *cause = NULL; /* Error explanation */
	struct addrinfo hints, *res, *res0;
	/* hints: will give hints about family (4 or 6) */
	/* res: pointer to a struct */
	/* res0: a linked list of struct */

	/* Initilazie the hints struct */
	memset(&hints, 0, sizeof(hints));
	/* For the moment, We didn't know what kind of family the IP given is */
	hints.ai_family = PF_UNSPEC;
	/* It's an TCP packet generator */
	hints.ai_socktype = SOCK_STREAM;

	/* The user give something as destination (ipv4, ipv6, hostname)
	   We need to call getaddrinfo that will looks for information
	   about (hints).
	   If successfull, res0 is a linked list of addrinfo structures */
	int error = getaddrinfo(host, ports, &hints, &res0);
	if (error) {
	        perror(gai_strerror(error));
	        return (-1);
	        /*NOTREACHED*/
	}

	/* We will try all results given in the res0 list one by one */
	int s = -1; /* s: socket  number */

	printf("Trying to connect to server...");
	while (s < 0) {
		for (res = res0; res; res = res->ai_next) {
			s = socket(res->ai_family, res->ai_socktype, 0);
			/* socket failed */
			if (s < 0) {
				cause = "socket";
				continue;
			}

			/* Try a connection to the socket */
			if (connect(s, res->ai_addr, res->ai_addrlen) < 0) {
				cause = "connect";
				close(s);
				s = -1;
				continue;
			}

			break;  /* okay we got one */
		}
	}
	/* if (s < 0) {
		perror(cause);
		return (-1);
	} */

	printf("Connected!\n");
	/* we have our socket, we don't need the list res0 anymore */
	freeaddrinfo(res0);

	printf("Sendfile %s toward %s:%lu (offset: %zu, nbytes: %zu, readahead: %u, flags: %u)\n", file, host, port, offset, nbytes, readahead, flags);

	off_t sendbytes=0;
	if ( sendfile(fd, s, offset, nbytes, NULL, &sendbytes,  SF_FLAGS(readahead, flags)) < 0) {
	printf("Sendfile %s at %s, port %lu\n", file, host, port);
		return (-1);
	}
	close(fd);
	printf("Done (sent %lu bytes)\n", sendbytes);
	return 0;
}
