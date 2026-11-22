#!/usr/bin/env python3
# Minimal RPKI-to-Router (RFC 6810, version 0) cache for frr_rpki_test.sh.
#
# Serves the VRPs of a CSV file (ASN,prefix,maxlen per line, '#' comments).
# On SIGHUP the file is re-read: the difference with the current set becomes
# a new serial, connected clients get a Serial Notify and fetch the delta with
# a Serial Query, as with a real cache. Records keep the file order, and one
# response is sent in a single write, so a large delta arrives as one burst.
#
# Usage: frr_rpki_rtrd.py <vrps.csv> <listen-addr> <port> <pidfile>
import ipaddress
import os
import selectors
import signal
import socket
import struct
import sys

SESSION_ID = 4242
VERSION = 0


def log(msg):
	print(msg, flush=True)


def load(path):
	vrps = []
	with open(path) as fh:
		for line in fh:
			line = line.split("#", 1)[0].strip()
			if not line:
				continue
			asn, pfx, maxlen = (f.strip() for f in line.split(","))
			net = ipaddress.ip_network(pfx)
			vrps.append((int(asn.upper().removeprefix("AS")), net, int(maxlen)))
	return vrps


def pdu_prefix(vrp, announce):
	asn, net, maxlen = vrp
	if net.version == 4:
		return struct.pack("!BBHIBBBB4sI", VERSION, 4, 0, 20, int(announce),
				   net.prefixlen, maxlen, 0, net.network_address.packed, asn)
	return struct.pack("!BBHIBBBB16sI", VERSION, 6, 0, 32, int(announce),
			   net.prefixlen, maxlen, 0, net.network_address.packed, asn)


def pdu_simple(ptype, session=SESSION_ID):
	return struct.pack("!BBHI", VERSION, ptype, session, 8)


def pdu_serial(ptype, serial):
	return struct.pack("!BBHII", VERSION, ptype, SESSION_ID, 12, serial)


class Cache:
	def __init__(self, path):
		self.path = path
		self.vrps = load(path)
		self.serial = 0
		# serial -> bytes of the records that lead from serial-1 to serial
		self.deltas = {}

	def reload(self):
		new = load(self.path)
		old_set, new_set = set(self.vrps), set(new)
		buf = b"".join(pdu_prefix(v, False) for v in self.vrps if v not in new_set)
		buf += b"".join(pdu_prefix(v, True) for v in new if v not in old_set)
		self.vrps = new
		self.serial += 1
		self.deltas[self.serial] = buf
		log(f"serial {self.serial}: {len(new)} VRPs, delta {len(buf)} bytes")

	def full(self):
		return (pdu_simple(3) + b"".join(pdu_prefix(v, True) for v in self.vrps)
			+ pdu_serial(7, self.serial))

	def since(self, serial):
		if serial == self.serial:
			return pdu_simple(3) + pdu_serial(7, self.serial)
		if serial > self.serial or serial + 1 not in self.deltas:
			return pdu_simple(8, 0)
		return (pdu_simple(3)
			+ b"".join(self.deltas[s] for s in range(serial + 1, self.serial + 1))
			+ pdu_serial(7, self.serial))


def recv_exact(sock, n):
	buf = b""
	while len(buf) < n:
		chunk = sock.recv(n - len(buf))
		if not chunk:
			raise ConnectionError("closed")
		buf += chunk
	return buf


def handle(sock, cache):
	ver, ptype, session, length = struct.unpack("!BBHI", recv_exact(sock, 8))
	body = recv_exact(sock, length - 8) if length > 8 else b""
	if ptype == 2:
		log(f"reset query (client version {ver})")
		sock.sendall(cache.full())
	elif ptype == 1:
		serial = struct.unpack("!I", body[:4])[0]
		log(f"serial query {serial} session {session}")
		if session != SESSION_ID:
			sock.sendall(pdu_simple(8, 0))
		else:
			sock.sendall(cache.since(serial))
	elif ptype == 10:
		log(f"error report from client: {body!r}")
		raise ConnectionError("error report")


def main():
	path, addr, port, pidfile = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
	cache = Cache(path)
	hup = []
	signal.signal(signal.SIGHUP, lambda *_: hup.append(1))
	signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

	srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
	srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	srv.bind((addr, port))
	srv.listen(4)
	with open(pidfile, "w") as fh:
		fh.write(f"{os.getpid()}\n")
	log(f"listening on {addr}:{port}, {len(cache.vrps)} VRPs")

	sel = selectors.DefaultSelector()
	sel.register(srv, selectors.EVENT_READ)
	clients = set()
	while True:
		for key, _ in sel.select(timeout=0.2):
			if key.fileobj is srv:
				c, peer = srv.accept()
				log(f"client {peer}")
				clients.add(c)
				sel.register(c, selectors.EVENT_READ)
				continue
			try:
				handle(key.fileobj, cache)
			except (ConnectionError, OSError):
				sel.unregister(key.fileobj)
				clients.discard(key.fileobj)
				key.fileobj.close()
		if hup:
			hup.clear()
			cache.reload()
			for c in clients:
				c.sendall(pdu_serial(0, cache.serial))


if __name__ == "__main__":
	main()
