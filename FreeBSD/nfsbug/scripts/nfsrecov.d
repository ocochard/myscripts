#!/usr/sbin/dtrace -qs
/*
 * nfsrecov.d -- timestamped NFSv4.1 client recovery trace.
 * Logs each SetClient (retok=-1: mount/umount, 1: CreateSession-only
 * recovery, 0: full recovery) with its mountpoint, the result of every
 * CreateSession/ExchangeID RPC, and every connect() made by efs-proxy, to
 * correlate EFS BADSESSION with proxy reconnects. Run with -o, not a
 * redirect: stdout to a pipe is block-buffered.
 */

fbt::nfsrpc_setclient:entry
{
	self->retokp = arg3;
	printf("%Y setclient start %s retok=%d\n", walltimestamp,
	    stringof(args[0]->nm_com.nmcom_mountp->mnt_stat.f_mntonname),
	    arg3 != 0 ? *(uint8_t *)arg3 : -1);
}

fbt::nfsrpc_setclient:return
/self->retokp/
{
	printf("%Y setclient ret=%d retok_out=%d\n", walltimestamp, arg1,
	    *(uint8_t *)self->retokp);
	self->retokp = 0;
}

fbt::nfsrpc_setclient:return
/!self->retokp/
{
	printf("%Y setclient ret=%d\n", walltimestamp, arg1);
}

fbt::nfsrpc_createsession:return
{
	printf("%Y createsession ret=%d\n", walltimestamp, arg1);
}

fbt::nfsrpc_exchangeid:return
{
	printf("%Y exchangeid ret=%d\n", walltimestamp, arg1);
}

syscall::connect:entry
/execname == "efs-proxy"/
{
	printf("%Y efs-proxy pid=%d connect fd=%d\n", walltimestamp, pid, arg0);
}

/*
 * TCP to EFS (port 2049): who connects, and who closes first.
 * CLOSE_WAIT = EFS sent FIN first; FIN_WAIT_1 = this host closed first.
 */
tcp:::connect-established
/args[4]->tcp_sport == 2049/
{
	printf("%Y tcp established local=%d -> efs:2049\n", walltimestamp,
	    args[4]->tcp_dport);
}

tcp:::state-change
/args[3]->tcps_rport == 2049 &&
 (args[3]->tcps_state == TCPS_CLOSE_WAIT ||
  args[3]->tcps_state == TCPS_FIN_WAIT_1 ||
  args[3]->tcps_state == TCPS_CLOSED)/
{
	printf("%Y tcp efs local=%d %s -> %s\n", walltimestamp,
	    args[3]->tcps_lport, tcp_state_string[args[5]->tcps_state],
	    tcp_state_string[args[3]->tcps_state]);
}

tcp:::receive
/args[4]->tcp_sport == 2049 && (args[4]->tcp_flags & TH_RST)/
{
	printf("%Y tcp RST from efs to local=%d\n", walltimestamp,
	    args[4]->tcp_dport);
}

/* Kernel NFS client to the local efs-proxy port: krpc reconnects. */
tcp:::connect-established
/args[4]->tcp_sport >= 20049 && args[4]->tcp_sport <= 21049/
{
	printf("%Y tcp nfs-client reconnect local=%d -> proxy:%d\n",
	    walltimestamp, args[4]->tcp_dport, args[4]->tcp_sport);
}
