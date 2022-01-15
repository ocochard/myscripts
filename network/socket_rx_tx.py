#!/usr/bin/env python
# Simple socket server/client used to send & receive data with setsockopt
# option to set DSCP.
# Used by TCP regression tests.
import socket
import argparse
import sys

dscp2hex = {
    'cs0':  0x00,
    'cs1':  0x20,
    'af11': 0x28,
    'af12': 0x30,
    'af13': 0x38,
    'cs2':  0x40,
    'af21': 0x48,
    'af22': 0x50,
    'af23': 0x58,
    'cs3':  0x60,
    'af31': 0x68,
    'af32': 0x70,
    'af33': 0x78,
    'cs4':  0x80,
    'af41': 0x88,
    'af42': 0x90,
    'af43': 0x98,
    'cs5':  0xa0,
    'va':   0xb0,
    'ef':   0xb8,
    'cs6':  0xc0,
    'cs7':  0xe0
}


def parse_args():
    parser = argparse.ArgumentParser(description='Simple socket server/client send/receive tool')
    parser.add_argument('-c', '--client', dest='client', action='store_true',
                        help='client mode (default is server)')
    parser.add_argument('-t', '--transmit', dest='transmit', action='store_true',
                        default=False, help='transmit data read from stdin (default is to wait for data and print them to stdout)')
    parser.add_argument('--host', type=str, default="127.0.0.1",
                        help='local or target IP (default 127.0.0.1)')
    parser.add_argument('-p', '--port', type=int, default="12345",
                        help='local or target port (default 12345)')
    parser.add_argument('-d', '--dscp', type=str, default="cs0",
                        help='DSCP value in form cs2, af41, ef, etc. (default cs0)')
    return parser.parse_args()


def main():
    args = parse_args()
    s = None

    for res in socket.getaddrinfo(args.host, args.port, socket.AF_UNSPEC, socket.SOCK_STREAM):
        af, socktype, proto, canonname, sa = res
        try:
            s = socket.socket(af, socktype, proto)
        except OSError as msg:
            s = None
            print(msg)
            continue

        if args.client:
            try:
                s.connect(sa)
            except OSError as msg:
                s.close()
                s = None
                print(msg)
                continue
        else:
            try:
                s.bind(sa)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                s.listen(1)
            except OSError as msg:
                s.close()
                s = None
                print(msg)
                continue

        try:
            if af == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_TCLASS, dscp2hex[args.dscp])
            elif af == socket.AF_INET:
                s.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, dscp2hex[args.dscp])
        except OSError as msg:
            s.close()
            s = None
            print(msg)
            continue
        break

    if s is None:
        print('Could not create and configure socket')
        sys.exit(1)

    if args.client:
        with s:
            if args.transmit:
                s.sendall(sys.stdin.buffer.read())
            else:
                while True:
                    data = s.recv(1024)
                    print(data)
                    if not data:
                        break
    else:
        conn, addr = s.accept()
        with conn:
            if args.transmit:
                conn.sendall(sys.stdin.buffer.read())
            else:
                while True:
                    data = conn.recv(1024)
                    print(data)
                    if not data:
                        break


if __name__ == '__main__':
    main()
