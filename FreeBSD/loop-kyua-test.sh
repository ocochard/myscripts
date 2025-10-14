#!/bin/sh
# run a test in a loop until it fails
# Example:
# sys/netlink/netlink_socket:sizes
# sys/aio/aio_test:vectored_big_iovcnt
set -eu
cd /usr/tests
i=1
while true; do
  echo run $i
  sudo kyua test $1
  i=$((i + 1))
done
