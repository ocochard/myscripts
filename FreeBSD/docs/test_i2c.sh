#!/bin/sh
# I2C Driver Test Script for FreeBSD Ampere Altra

echo "========================================"
echo "I2C Driver Functionality Test"
echo "========================================"
echo ""

echo "=== Test 1: Scan I2C Bus 0 ==="
i2c -s -f /dev/iic0
echo ""

echo "=== Test 2: Scan I2C Bus 1 ==="
i2c -s -f /dev/iic1
echo ""

echo "=== Test 3: Read 8 bytes from 0x10 (Bus 0) ==="
i2c -f /dev/iic0 -a 0x10 -c 8 -d r
echo ""

echo "=== Test 4: Read 4 bytes from 0x51 (Bus 1) ==="
i2c -f /dev/iic1 -a 0x51 -c 4 -d r
echo ""

echo "=== Test 5: Read 4 bytes from 0x11 (Bus 1) ==="
i2c -f /dev/iic1 -a 0x11 -c 4 -d r
echo ""

echo "=== Test 6: Check for errors in dmesg ==="
dmesg | grep -E "dw_i2c|timeout|abort" | tail -10
echo ""

echo "========================================"
echo "All tests completed!"
echo "========================================"
