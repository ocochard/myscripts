# Generic variable definition

: ${TMPDIR=/tmp}
SRCDIR=`atf_get_srcdir`
HOST=127.0.0.1
PORT=9090
SIZE=2000000000

# Simple send with default option
atf_test_case default cleanup
default_head()
{
        atf_set descr "sendfile a ${SIZE} file using empty default value"
}

default_body()
{
        ist_test "" ${SIZE}
}

default_cleanup()
{
        ist_cleanup
}

# Simple send with NOCACHE flag
atf_test_case sf_nocache cleanup
sf_nocache_head()
{
        atf_set descr "sendfile a ${SIZE} file using SF_NOCACHE flag"
}

sf_nocache_body()
{
        ist_test "-c" ${SIZE}
}

sf_nocache_cleanup()
{
        ist_cleanup
}

# Simple send with SF_SYNC flag
atf_test_case sf_sync cleanup
sf_sync_head()
{
        atf_set descr "sendfile a ${SIZE} file using SF_NOCACHE"
}

sf_sync_body()
{
        ist_test "-s" ${SIZE}
}

sf_sync_cleanup()
{
        ist_cleanup
}

# Simple send with SF_NODISKIO flag
atf_test_case flag_nodiskio cleanup
sf_nodiskio_head()
{
        atf_set descr "sendfile a ${SIZE} file using SF_NODISKIO"
}

sf_nodiskio_body()
{
        ist_test "-d" ${SIZE}
}

sf_nodiskio_cleanup()
{
        ist_cleanup
}

# Simple send with SF_USER_READAHEAD flag
atf_test_case sf_user_readahead cleanup
sf_user_readahead_head()
{
        atf_set descr "sendfile a ${SIZE} bytes file using SF_USER_READAHEAD and 4 pages"
}

sf_user_readahead_body()
{
        ist_test "-u -r 4" ${SIZE}
}

sf_user_readahead_cleanup()
{
        ist_cleanup
}

# Simple send sending half number of bytes
atf_test_case halfbytes cleanup
halfbytes_head()
{
		HALF=$(( SIZE / 2 ))
        atf_set descr "sendfile only a ${HALF} byte from the ${SIZE} file using empty default value"
}

halfbytes_body()
{
		HALF=$(( SIZE / 2 ))
        ist_test "-n ${HALF}" ${HALF}
}

halfbytes_cleanup()
{
        ist_cleanup
}

#### Full test list ###
atf_init_test_cases()
{
    atf_add_test_case default
	atf_add_test_case sf_nocache
	atf_add_test_case sf_sync
	atf_add_test_case sf_nodiskio
	atf_add_test_case sf_user_readahead
	atf_add_test_case halfbytes
}

#### Generic functions

ist_createfile ()
{
	# TO DO 2 methods:
	# non-cached: already done with truncate
	# already cached file (on a tmpfs storage?)
    truncate -s ${SIZE} ${TMPDIR}/sender-file
}

ist_receiver ()
{
    [ -f ${TMPDIR}/received.bin ] && rm -f ${TMPDIR}/receiver-file
    atf_check -o match:Done ${SRCDIR}/receiver -f ${TMPDIR}/receiver-file -h ${HOST} -p ${PORT}
}

ist_sender ()
{
    atf_check -s exit:0 -o match:Done ${SRCDIR}/sender -f ${TMPDIR}/sender-file -h ${HOST} -p ${PORT} $1
}

ist_test()
{
	# $1: sendfile parameters
	# $2: receiving file size
    ist_createfile
    ist_receiver &
    ist_sender "$1"
	atf_check -s exit:0 -o match:$2 stat -f%z ${TMPDIR}/receiver-file
}

ist_cleanup()
{
    [ -f ${TMPDIR}/sender-file ] && rm -f ${TMPDIR}/sender-file
    [ -f ${TMPDIR}/receiver-file ] && rm -f ${TMPDIR}/receiver-file
}
