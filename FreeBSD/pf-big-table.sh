#!/bin/sh
# Testing multiple load of the same big table
set -eu
if ! kldstat -m pf; then
	echo "pf not loaded, loading it"
	sudo kldload pf
fi
echo "Loading a public IPv4 blocklist"
if [ ! -r prod_data-shield_ipv4_blocklist.txt ]; then
	fetch https://raw.githubusercontent.com/duggytuxy/Data-Shield_IPv4_Blocklist/refs/heads/main/prod_data-shield_ipv4_blocklist.txt
fi
entries=$(wc -l prod_data-shield_ipv4_blocklist.txt | awk '{print $1}')
#sudo sysctl net.pf.request_maxcount=100000
maxcount=$(sysctl -n net.pf.request_maxcount)
if [ ${entries} -gt ${maxcount} ]; then
	echo "System’s net.pf.request_maxcount ($maxcount) too small to load this $entries elements table"
	echo "Increasing it..."
	sudo sysctl net.pf.request_maxcount=$(( ${entries} + 1 ))
fi
# why do we need bigger table entry than the real table
# set limit table-entries 400000
cat <<'EOF' >pf.conf
table <shield_ipv4.blocklist> persist file "prod_data-shield_ipv4_blocklist.txt"
EOF
echo "System configured with net.pf.request_maxcount ${maxcount} loading a ${entries} table multiple times"
for i in $(jot 10); do
	echo "Try: $i"
	echo "current VM usage"
	vmstat -z | awk 'NR==1; /table entries/{print; exit}'
	sudo pfctl -f pf.conf
done
