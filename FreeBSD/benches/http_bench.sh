#!/bin/sh
# Simple nginx/wrk bench script
# Concept by Brad Davis (brd@FreeBSD.org)
# In server mode: Generate nginx simple setup with some data files
# In client mode: Start wrk against given host
# Usage:
# - No arg: start in server mode
# - IP or hostname as arg: start in client mode

set -eu -o pipefail

WWW_DATA=/tmp/www

start_nginx() {
	if ! which nginx; then
		echo "Need nginx installed"
		exit 1
	fi
	# Create some test files
	TESTCOUNT=0
	TESTMAX=30
	mkdir -p ${WWW_DATA}
	while [ ${TESTCOUNT} -le ${TESTMAX} ]; do
		dd if=/dev/urandom bs=1m count=20 of=${WWW_DATA}/test${TESTCOUNT}
		TESTCOUNT=$(( ${TESTCOUNT} + 1 ))
	done

	# Configure nginx
	cat << EOF > /usr/local/etc/nginx/nginx.conf
worker_processes auto;
events {
	worker_connections  1024;
}
http {
	include mime.types;
	default_type application/octet-stream;
	sendfile on;
	error_log  off;
	access_log off;
	server {
        	listen 80;
			server_name $(hostname);
		location / {
			root ${WWW_DATA}/;
		}
	}
}
EOF

	# Start up nginx
	service nginx onestart
}

start_wrk() {
	if ! which wrk; then
		echo "Need wrk installed"
		exit 1
	fi
	SERVERIP=$1
	echo "Start executing tests against: ${SERVERIP}"
	cat << EOF > /tmp/random.lua
-- generate a request for a random file named test[0-30]

request = function()
   num = math.random(0,30)
   path = "/test" .. num
   wrk.headers["X-Test"] = "test" .. num
   return wrk.format(nil, path)
end

done = function(summary, latency, requests)
    file = io.open('/tmp/result.json', 'a')
    io.output(file)
    io.write(string.format("{\"requests_sec\":%.2f, \"transfer_sec\":%.2fMB, \"avg_latency_ms\":%.2f, \"errors_sum\":%.2f, \"duration\":%.2f,\"requests\":%.2f, \"bytes\":%.2f, \"latency.min\":%.2f, \"latency.max\":%.2f, \"latency.mean\":%.2f, \"latency.stdev\":%.2f}",
            summary.requests/(summary.duration/1000000),
            summary.bytes/(summary.duration*1048576/1000000),
            (latency.mean/1000),
            summary.errors.connect + summary.errors.read + summary.errors.write + summary.errors.status + summary.errors.timeout,
            summary.duration,
            summary.requests,
            summary.bytes,
            latency.min,
            latency.max,
            latency.mean,
            latency.stdev
        )
    )
end
EOF
	wrk -c2500 -d5m -t30 -s /tmp/random.lua http://${SERVERIP}
	echo "Tests finished"
}

if [ $# -eq 1 ]; then
	echo "Client mode targetting $1"
	start_wrk $1
else
	echo "Server mode: starting nginx"
  if [ $(id -u) -ne 0 ]; then
    echo "Need root permission to configure and restart nginx"
    exit 1
  fi
	service nginx onestop || true
	start_nginx
fi
