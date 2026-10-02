#!/bin/sh
# Return true if temperature less than 80°C
temp=$(sysctl -n dev.amdtemp.0.core0.sensor0 | tr -dc '0-9.')
threshold=85
if [ $(echo "$temp > $threshold" | bc) -eq 1 ]; then
	echo "CPU temp too high (${temp})°C"
    exit 1
else
    exit 0
fi
