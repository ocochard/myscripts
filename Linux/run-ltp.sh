#!/usr/bin/env bash
# Install and run Linux Test Project
# https://github.com/linux-test-project/ltp
set -eu
ltp_version="20250930"
workdir="/tmp/ltp"
mkdir -p ${workdir}
git clone --depth 1 --branch ${ltp_version} https://github.com/linux-test-project/ltp.git ${workdir}
cd ${workdir}
./configure
make
make install
make install-testsuite
make install-testsuite-man
make install-testsuite-html
make install-testsuite-man-html