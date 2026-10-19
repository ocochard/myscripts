#!/bin/sh
set -eu
i=0
usage() {
  echo "$0 command-line"
  exit 0
}
if [ $# -lt 1 ]; then
  usage
fi
while sudo kyua test sys/aio/aio_test:vectored_big_iovcnt; do
  i=$((i + 1 ))
  echo loop $i
done
