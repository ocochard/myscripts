Experimental TCP DSCP marking tests regression tests
Copy this folder into /usr/src/tests
cd /usr/src/tests
cd tcp_dscp
mkdir /usr/tests/sys/sendfile
make & make install
kyua test -k /usr/tests/Kyuafile sys/sendfile/
