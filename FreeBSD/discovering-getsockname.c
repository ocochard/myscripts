// vim: tabstop=8 shiftwidth=8 columns=80 smarttab cindent noexpandtab
/* sendfile(2) regression test */

#include <stdio.h> /* perror */
#include <stdlib.h> /* exit */
#include <string.h> /* memset */
#include <unistd.h> /* close */
#include <sys/socket.h> /* it's a network software */
#include <netdb.h> /* getaddrinfo */
#include <arpa/inet.h> /* ntohs */
#include <netinet/in.h> /*  sockaddr_in */

int main(int argc, char *argv[]){

	char host[NI_MAXHOST]="127.0.0.1",port[NI_MAXSERV]="0";

	const char *cause = NULL; /* Error explanation */

	struct addrinfo hints, *res, *res0;

	struct sockaddr server,client;
	/* hints: will give hints about family (4 or 6) */
	/* res: pointer to a struct */
	/* res0: a linked list of struct */

	/* Initilazie the hints struct */
	memset(&hints, 0, sizeof(hints));

	/* IP v4 only for this test */
	hints.ai_family = AF_INET;
	/* Only return configured IP addresses and disable resolution name */
	hints.ai_flags = AI_ADDRCONFIG|AI_NUMERICSERV|AI_NUMERICHOST;
	/* It's an TCP server */
	hints.ai_socktype = SOCK_STREAM;
	/* Accept any protocol */
	hints.ai_protocol = 0;
	/*   We need to call getaddrinfo that will looks for information
	   about (hints).
	   If successfull, res0 is a linked list of addrinfo structures */
	int error = getaddrinfo(host, port, &hints, &res0);

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
		/* Not mandatory here, it will be able to listen
		   without binding to it, but the getsockname will
		   return a 0 for IP address */
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

	socklen_t len = res->ai_addrlen;
	/* we have our socket, we don't need the list res0 anymore */
	freeaddrinfo(res0);

	printf("Listen on (instructed) %s:%s\n", host, port);

	/* Using a dynamic ports, then retrieve it using getsockname */
	/* Initialize the server struct */
	memset(&server, 0, sizeof(server));

	error = getsockname(s, &server, &len);
	if (error < 0) {
		perror(cause);
		return (-1);
		/*NOTREACHED*/
	}

	/* To retreive the sin_addr or sin_port from a sockaddr struct
	   we need to cast it into a sockaddr_in */

	struct sockaddr_in *server_in = (struct sockaddr_in *)&server;

	printf("listen on (getsockname) %s:%d\n",inet_ntoa(server_in->sin_addr),ntohs(server_in->sin_port));

	printf("Waiting for a client...");

	/* Initialize the client struct */
	memset(&client, 0, sizeof(client));
	len = client.sa_len;

	/* Wait for one client only */

	int sockfd = accept(s, &client, &len);
	if (sockfd < 0) {
		perror("accept");
		close(s);
		return (-1);
	}

	printf("Connected! now exiting\n");

	close(s);
	return EXIT_SUCCESS;
}
