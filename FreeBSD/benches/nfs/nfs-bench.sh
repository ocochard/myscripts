#!/bin/sh
# Benching NFSv4 performance
# Configure and bench client and server
set -eu
SRV_IP=1.1.1.30
WRKDIR=/tmp/nfs
dd_write="dd if=/dev/zero of=$WRKDIR/data bs=1M count=20480"
dd_read="dd if=$WRKDIR/data of=/dev/zero bs=1M count=20480"

usage () {
	echo "$0 client|server"
	exit 1
}

sysctl_tcp () {
	for i in $1; do
		sysctl $i
	done
	# XXX: Need to read all sysctl validate tuning is applied
}

bench_client() {
	# XXX: Need to save median, min, max values
	if [ "$1" = "write"]; then
		echo "client writing to server:"
		$dd_write
	elif [ "$1" = "read"]; then
		echo "client reading from server:"
		$dd_read
	else
		echo "BUG callling bench_client()"
		exit 1
	fi
	rm $WRKDIR/data
}

bench_server() {
	display_sysctl
	service nfsd restart
}

display_sysctl() {
	echo "System parameters:"
	for i in $sysctl_list; do
		sysctl $i
	done
}

if [ $# -ne 1 ]; then
	usage
fi
type=$1

echo "This is a NFS client and server bench script"
echo "On a server side, it will mount a 30G tmpfs, configure NFSv4 (so /etc/exports and /etc/rc.conf) and bench the local tmpfs read/write performance"
echo "On a client side, it will mount the NFS server and bench the performance"
echo "The script as to be run as root and started on both side (client and server)"
echo "It will loop using multiples TCP and NFSv4 parameters and report the results"

echo "Press Enter to configure this system as $type and continue or Ctrl-C to abort"
read dummy

if [ "$(id -u)" -ne 0 ]; then
	echo "This script must be run as root"
	exit 1
fi

client_params='
nconnect=1
nconnect=16
nconnect=16,wcommitsize=67108864
nconnect=16,wcommitsize=67108864,readahead=8
nconnect=16,wcommitsize=67108864,readahead=8,nocto
'

# XX to do
# /boot/loader.conf vfs.maxbcachebuf=1048576
sysctl_list='
kern.ipc.maxsockbuf
net.inet.tcp.recvbuf_max
net.inet.tcp.sendbuf_max
net.inet.tcp.recvspace
net.inet.tcp.sendspace
vfs.nfsd.srvmaxio
vfs.nfs.iodmax
'

tcp_params_default='
kern.ipc.maxsockbuf=2097152
net.inet.tcp.recvbuf_max=2097152
net.inet.tcp.sendbuf_max=2097152
net.inet.tcp.recvspace=65536
net.inet.tcp.sendspace=32768
'

tcp_params_x4='
kern.ipc.maxsockbuf=8388608
net.inet.tcp.recvbuf_max=8388608
net.inet.tcp.sendbuf_max=8388608
net.inet.tcp.recvspace=262144
net.inet.tcp.sendspace=131072
'

tcp_params_x16='
kern.ipc.maxsockbuf=33554432
net.inet.tcp.recvbuf_max=33554432
net.inet.tcp.sendbuf_max=33554432
net.inet.tcp.recvspace=1048576
net.inet.tcp.sendspace=524288
'

mkdir -p $WRKDIR

if mount | grep -q "$WRKDIR"; then
	if [ "$type" = "client" ] ; then
		echo "$WRKDIR already NFS mounted, need to unmount"
		umount $WRKDIR
	fi
else
	if [ "$type" = "server" ] ; then
		echo "Mounting 30G tmpfs in $WRKDIR"
		mount -t tmpfs -o rw,size=30g,mode=777 tmpfs $WRKDIR
	fi
fi

if grep -q "^nfs" /etc/rc.conf; then
	echo "NFS is already enabled in /etc/rc.conf, abort"
	exit 1
fi

if [ "$type" = "server" ] ; then
	echo "Configuring NFSv4 server"
	if [ -f /etc/exports ]; then
		echo "/etc/exports already existing, abort"
		exit 1
	else
		echo "Creating /etc/exports"
		(
			echo "V4: /tmp"
			echo "$WRKDIR -network 1.1.1.0/24"
		) > /etc/exports
		sysrc nfs_server_enable=YES
		sysrc nfsv4_server_enable=YES
		sysrc nfsv4_server_only=YES
		for i in nfs_server_flags nfs_server_maxio nfs_reserved_port_only nfs_bufpackets; do
			sysrc -x $i
		done
	fi
	echo "Local (server) dd benchmark for reference values:"
	$dd_write
	$dd_read
	rm $WRKDIR/data
else
	# client side
	sysrc nfs_client_enable=YES
	echo "Wait for instructions on the server before pressing Enter to continue"
	read dummy
fi

# Loop through TCP parameter sets
for tcp_set in "tcp_params_default" "tcp_params_x4" "tcp_params_x16"; do
	echo "= Loop on TCP parameters: $tcp_set ="
	eval "sysctl_tcp \"\$$tcp_set\""

	if [ "$type" = "client" ] ; then
		service nfsclient restart
		for i in $client_params; do
			echo "== Loop on NFSv4 client mount parameters: $i =="
			mount -t nfs -o noatime,nfsv4,$i $SRV_IP:/nfs $WRKDIR/
			display_sysctl
			nfsstat -m
			bench_client read $tcp_set maxio_default
			umount $WRKDIR
			bench_client write $tcp_set maxio_default
			umount $WRKDIR
		done
		echo "Client finished loop"
		echo "Now, on the server, press Enter to loop into next TCP parameters before continuing on the client"
		read dummy
	else
		bench_server
		echo "You can start the client bench now"
		echo "Waiting for client benches to finish TCP parameters loop: $tcp_set"
		echo "Press Enter once instructed on the client"
		read dummy
		service nfsd stop
	fi

done # tcp_params
echo "DEBUG: tcp_set: $tcp_set"

if [ "$type" = "server" ] ; then
	# At this stage, TCP stack has the X 4 values, so be ready to increase maxio
	sysrc nfsd_nfs_server_maxio="1048576"
	bench_server
	echo "Waiting for client benches to finish the last loop"
	echo "Press Enter when client finished its benches"
	read dummy
	service nfsd stop
	sysrc -x nfs_server_enable
	sysrc -x nfsv4_server_enable
	sysrc -x nfsv4_server_only
	rm /etc/exports
else
	echo "Now, on the server, press Enter to continue to next loop"
	read dummy
	echo "Loop on NFSv4 client mount parameters..."
	for i in $client_params; do
		echo "Benching: $i"
		mount -t nfs -o noatime,nfsv4,$i $SRV_IP:$WRKDIR $WRKDIR/
		nfsstat -m
		bench_client read $tcp_set maxio_default
		umount $WRKDIR
		bench_client write $tcp_set maxio_default
	done
	sysrc -x nfs_client_enable
fi

echo "Benchmark completed for $type"
