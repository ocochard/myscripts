// vim: tabstop=8 shiftwidth=8 columns=80 smarttab cindent noexpandtab
/* TCP DSCP server regression test */

#include <fcntl.h> /* open */
#include <stdio.h> /* fprintf */
#include <stdlib.h> /* exit */
#include <string.h> /* atoi */
#include <unistd.h> /* getopt, setuid, getuid, close */
#include <sysexits.h> /* EX_USAGE */
#include <sys/stat.h> /* S_IWUSR | S_IRUSR */
//#include <sys/types.h> /* needed by sendfile */
#include <sys/socket.h> /* it's a network software */
#include <netinet/in.h>
#include <netdb.h> /* getaddrinfo */
#include <errno.h> /* sendfile uses errno */
#include <arpa/inet.h> /* inet_ntop */


static void usage(void){
	fprintf(stderr,"Usage:\n");
	fprintf(stderr," -f : filename\n");
	fprintf(stderr," -h : hostname or IP address\n");
	fprintf(stderr," -p : port number\n");
	exit(EX_USAGE);
}

int main(int argc, char *argv[]){

	unsigned long port=0;	/* TCP destination port */
	char *dummy;		/* mandatory for strtoul but not used */
	int tos = -1;		/* Type of Service */
	char host[NI_MAXHOST]={0},ports[NI_MAXSERV]={0},file[256]={0};

	for (;;) {
		int opt = getopt(argc, argv, "f:h:p:");
		if (opt == -1) {
			break; /* exit for loop when reach end of argv */
		}
		switch (opt) {
		case 'f':
			strcpy(file, optarg );
			break;
		case 'h':
			strcpy(host, optarg );
			break;
		case 'p':
			strcpy(ports, optarg );
			/* convert the string "port" to unsigned_long */
			port = strtoul(ports, &dummy, 10);
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

	if (host[0] == 0) {
		fprintf(stderr, "Missing hostname\n");
		usage();
	}
	const char *cause = NULL; /* Error explanation */

	struct addrinfo hints, *res, *res0;
	struct sockaddr client;

	/* hints: will give hints about family (4 or 6) */
	/* res: pointer to a struct */
	/* res0: a linked list of struct */

	/* Initilazie the hints struct */
	memset(&hints, 0, sizeof(hints));
	/* For the moment, We didn't know what kind of family the IP given is */
	hints.ai_family = PF_UNSPEC;
	/* It's an TCP server */
	/* does sendfile works over UDP? */
	hints.ai_socktype = SOCK_STREAM;

	/* The user give something to listen to (ipv4, ipv6, hostname)
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
	for (res = res0; res; res = res->ai_next) {
		s = socket(res->ai_family, res->ai_socktype, 0);
		/* socket failed */
		if (s < 0) {
			cause = "socket";
			continue;
		}

		/* Try to bind the socket */
		if (bind(s, res->ai_addr, res->ai_addrlen) < 0) {
			cause = "bind";
			close(s);
			s = -1;
			continue;
		}

		/* Try to listen the socket */
		if (listen(s, 5) < 0) {
			cause = "listen";
			close(s);
			s = -1;
			continue;
		}

		break;  /* okay we got one */
	}
	if (s < 0) {
		perror(cause);
		freeaddrinfo(res0);
		return (-1);
		/*NOTREACHED*/
	}

	/* we have our socket, we don't need the list res0 anymore */
	freeaddrinfo(res0);

	printf("Having socket, set TOS to it...\n")
	int proto, option;

	if (af == AF_INET6) {
		proto = IPPROTO_IPV6;
		option = IPV6_TCLASS;
	} else {
		proto = IPPROTO_IP;
		option = IP_TOS;
	}
	if (setsockopt(s, proto, option, &Tflag, sizeof(Tflag)) == -1)
		err(1, "set IP ToS");

	printf("Listen and wrote into file %s at %s, port %lu\n", file, host, port);
	char buffer[BUFSIZ];
	int read_return = 0;
	long unsigned int bytes=0;
	printf("Waiting for a client...");

       /* Initialize the client struct */
	memset(&client, 0, sizeof(client));
	socklen_t foo = client.sa_len;

	/* Wait for one client only */
	int sockfd = accept(s, &client, &foo);
	if (sockfd < 0) {
		perror("accept");
		close(s);
		return (-1);
	}

	printf("Connected!\nWriting into file...\n");
	int fd = open(file, O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR);
	if(fd < 0) {
		fprintf(stderr, "open file error: %s\n", strerror(errno));
		usage();
	}
	do {
		read_return = read(sockfd, buffer, BUFSIZ);
		if (read_return < 0 ) {
			perror("read accept");
			close(fd);
			close(s);
			return(-1);
		}
		bytes += read_return;
		if (write(fd, buffer, read_return) < 0) {
			perror("write socket to file");
			close(fd);
			close(s);
			return(-1);
		}
	} while (read_return > 0);
	printf("Done (received %lu bytes)\n", bytes);

	close(fd);
	close(s);
	return EXIT_SUCCESS;
}
