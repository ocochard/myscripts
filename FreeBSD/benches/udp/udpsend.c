/* Simple packet (UDP) benchmark */
/* With lot's of comments (I'm learning C coding) */

#define PAYLOAD_STRING "0123456789"
#define PAYLOAD_SIZE 10

#include <stdio.h>
#include <signal.h> /* signal handler */
#include <stdlib.h> /* exit */
#include <string.h> /* atoi */
#include <unistd.h> /* setuid, getuid, close */

#include <sys/socket.h>

#include <netinet/in.h>
#include <netdb.h> /* getaddrinfo */

/* Global variable */
static int global_stop_flag = 0; /* allow to exit infinite loop */

/* Display usage */
static void
usage(void)
{
	fprintf(stderr,"udpsocket <host> <port>\n");
	exit(-1);
}

/* Catch signal */
static void
signal_handler(int signum __unused)
{
    global_stop_flag = 1;
}

int
main(int argc, char *argv[])
{
	struct addrinfo hints={0}, *res, *res0;
	/* hints: will give hints about family (4 or 6) */
	/* res: pointer to a struct */
	/* res0: a linked list of struct */
	hints.ai_family = PF_UNSPEC; /* For the moment, We didn't know what kind of family the IP given is */
	hints.ai_socktype = SOCK_DGRAM; /* It's an UDP packet generator */

	/* If not a minimum of 3 argument given display usage */
	if(argc != 3)
		usage();

	/* convert the string "port" to unsigned_long */
	char *dummy; /* mandatory for strtoul but not used */
	unsigned long port = strtoul(argv[2], &dummy, 10);
	/* now we can check the boundary of the port number */
	if (port < 1 || port > 65535 || *dummy != '\0') {
		fprintf(stderr, "Invalid port number: %s\n", argv[2]);
		usage();
		/*NOTREACHED*/
	}
	/* The user give something as destination (ipv4, ipv6, hostname) */
	/* We need to call getaddrinfo that will looks for information about (hints) */
	/* argv[1]: destination server/ip */
	/* argv[2]: destination port */
	/* If successfull, res0 is a linked list of addrinfo structures */
	int error = getaddrinfo(argv[1], argv[2], &hints, &res0);
	if (error) {
	        perror(gai_strerror(error));
	        return (-1);
	        /*NOTREACHED*/
	}

	/* We will try all results given in the res0 list one by one */
	int s = -1; /* socket number */
	const char *cause = NULL; /* Error explanation */
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
	if (s < 0) {
		perror(cause);
		return (-1);
		/*NOTREACHED*/
	}

	/* we have our socket, we don't need the list res0 anymore */
	freeaddrinfo(res0);

	printf("Sending packet at %s, port %s\n", argv[1], argv[2]);

	unsigned long send_errors = 0, send_calls = 0;

	/* Before the infinite loop, configure a signal handler
	   here we want to catch a Ctrl+C */
	signal(SIGINT, signal_handler);
	/* Infinite loop of send() */
	while(global_stop_flag == 0) {
		if (send(s, PAYLOAD_STRING, PAYLOAD_SIZE, 0) < 0)
			send_errors++;
        	send_calls++;
	}
	printf("socket calls: %ld\n", send_calls);
	printf("socket errors: %ld\n",send_errors);
}

