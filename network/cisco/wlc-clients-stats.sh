#!/bin/sh

# Get from a Cisco WLC a table of connected station and link quality
# by using snmpget

set -eu

host="${1:-localhost}"
community="${2:-public}"
args="-Oq -On -OE -v2c -c $community $host"

# MIB definition
# http://www.oidview.com/mibs/14179/AIRESPACE-WIRELESS-MIB.html
bsnMobileStationMacAddress="1.3.6.1.4.1.14179.2.1.4.1.1"
bsnMobileStationRSSI="1.3.6.1.4.1.14179.2.1.6.1.1"
bsnMobileStationSnr="1.3.6.1.4.1.14179.2.1.6.1.26"
bsnMobileStationUserName="1.3.6.1.4.1.14179.2.1.4.1.3"
bsnMobileStationSsid="1.3.6.1.4.1.14179.2.1.4.1.7"
bsnMobileStationProtocol="1.3.6.1.4.1.14179.2.1.4.1.25"
bsnMobileStationAPMacAddr="1.3.6.1.4.1.14179.2.1.4.1.4"
bsnMobileStationStatusCode="1.3.6.1.4.1.14179.2.1.4.1.42"

bsnAPDot3MacAddress="1.3.6.1.4.1.14179.2.2.1.1.1"
bsnAPName="1.3.6.1.4.1.14179.2.2.1.1.3"

# Start by generating a list of AP MAC=>NAME
# Variable will have AP_MAC name
# We can't export variable in a "while read" loop
# workaround: export in a file and source them
[ -f stupidshell ] && rm stupidshell
snmpwalk $args ${bsnAPDot3MacAddress} | while read line; do
	IDX=`echo $line | cut -d ' ' -f 1 | cut -d '.' -f 14-19`
	MAC=`echo $line | cut -d '"' -f 2 | tr -d '[[:space:]]'`
	APNAME=`snmpget -Ov $args ${bsnAPName}.${IDX}`
	echo "AP_${MAC}=${APNAME}" >> stupidshell
done

# 
echo "Station hostname;Station MAC;Protocol Used;Connected to AP;Received Signal Strength Indicator;Signal-to-Noise Ratio;Quality (RSSI/SNR);WLAN SSID;STATUS"
snmpwalk $args ${bsnMobileStationMacAddress} | while read line; do
	#Load variable stored during the previous subshell/while loop
	. stupidshell.sh
	IDX=`echo $line | cut -d ' ' -f 1 | cut -d '.' -f 14-19`
	MAC=`echo $line | cut -d '"' -f 2 | tr -s ' ' ':' | cut -d ':' -f 1-6`
	RSSI=`snmpget -Ov $args ${bsnMobileStationRSSI}.${IDX}`
	SNR=`snmpget -Ov $args ${bsnMobileStationSnr}.${IDX}`
	HOSTNAME=`snmpget -Ov $args ${bsnMobileStationUserName}.${IDX} | cut -d '"' -f 2`
	[ -z "${HOSTNAME}" ] && HOSTNAME="Unknown"
	SSID=`snmpget -Ov $args ${bsnMobileStationSsid}.${IDX} | cut -d '"' -f 2`
	PROTO=`snmpget -Ov $args ${bsnMobileStationProtocol}.${IDX}`
	APMAC=`snmpget -Ov $args ${bsnMobileStationAPMacAddr}.${IDX} | cut -d '"' -f 2 | tr -d '[[:space:]]'`
	STATUS=`snmpget -Ov $args ${bsnMobileStationStatusCode}.${IDX}`
	# resolve APMAC->NAME
	eval CAPNAME=\$AP_$APMAC
	[ $RSSI -gt -80 ] && RSSI_QLTY="Good" || RSSI_QLTY="Bad"
	[ $RSSI -gt -65 ] && RSSI_QLTY="Excellent"
	[ $SNR -gt 20 ] && SNR_QLTY="Good" || SNR_QLTY="Bad"
	[ $SNR -gt 40 ] && SNR_QLTY="Excellent"
	case "${PROTO}" in
	1)
		PROTO="802.11a"
		;;
	2)
		PROTO="802.11b"
		;;
	3)	
		PROTO="802.11g"
		;;
	6)
		PROTO="802.11bn"
		;;
	7)
		PROTO="802.11an"
		;;
	esac
	case "${STATUS}" in
	0)
		STATUS="Associated"
		;;
	esac	
	echo "${HOSTNAME};${MAC};${PROTO};${CAPNAME};${RSSI};${SNR};${RSSI_QLTY}/${SNR_QLTY};${SSID};${STATUS}"
done
