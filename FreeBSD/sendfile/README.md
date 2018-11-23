Experimental sendfile(8) regression tests
Copy this folder into /usr/src/tests
cd /usr/src/tests
cd sendfile
mkdir /usr/tests/sys/sendfile
make & make install
kyua test -k /usr/tests/Kyuafile sys/sendfile/
