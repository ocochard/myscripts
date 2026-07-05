#!/bin/sh
# QEMU launcher with UEFI HTTP netboot (no disk image needed)
#
# Requires virtio-rng-pci: EDK2 network stack has a hard dependency on the RNG
# protocol (gEfiRngProtocolGuid); without it boot silently fails.
# PXE is disabled via fw_cfg to skip the 75s IPv4/IPv6 PXE timeout sequence.
set -eu

usage() {
	echo "Usage: ${0##*/} [-netboot]"
	echo "  -netboot  Boot netboot.xyz via UEFI HTTP (downloaded directly by UEFI)"
	exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }

NETBOOT=false

while [ $# -gt 0 ]; do
	case "$1" in
	-netboot) NETBOOT=true ;;
	-h|--help) usage ;;
	*) usage ;;
	esac
	shift
done

# Detect host architecture
ARCH=$(uname -m)
case "$ARCH" in
x86_64|amd64)
	QEMU_BIN=qemu-system-x86_64
	QEMU_CPU=max
	QEMU_MACHINE=q35
	EFI_CODE_CANDIDATES="
		/usr/share/qemu/edk2-x86_64-code.fd
		/usr/share/OVMF/OVMF_CODE_4M.fd
		/usr/share/OVMF/OVMF_CODE.fd
		/usr/share/edk2/ovmf/OVMF_CODE.fd
		/opt/homebrew/share/qemu/edk2-x86_64-code.fd
		/usr/local/share/qemu/edk2-x86_64-code.fd
	"
	EFI_VARS_CANDIDATES="
		/usr/share/qemu/edk2-i386-vars.fd
		/usr/share/OVMF/OVMF_VARS_4M.fd
		/usr/share/OVMF/OVMF_VARS.fd
		/usr/share/edk2/ovmf/OVMF_VARS.fd
		/opt/homebrew/share/qemu/edk2-i386-vars.fd
		/usr/local/share/qemu/edk2-i386-vars.fd
	"
	# Use http:// — EDK2 hardcodes OpenSSL security level 3 which rejects
	# RSA-2048 certs (used by netboot.xyz on AWS), so https TLS handshake fails
	NETBOOT_URL="http://boot.netboot.xyz/ipxe/netboot.xyz.efi"
	;;
aarch64|arm64)
	QEMU_BIN=qemu-system-aarch64
	QEMU_CPU=cortex-a57
	QEMU_MACHINE=virt
	EFI_CODE_CANDIDATES="
		/usr/share/qemu/edk2-aarch64-code.fd
		/usr/share/AAVMF/AAVMF_CODE.fd
		/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw
		/opt/homebrew/share/qemu/edk2-aarch64-code.fd
		/usr/local/share/qemu/edk2-aarch64-code.fd
	"
	EFI_VARS_CANDIDATES="
		/usr/share/qemu/edk2-arm-vars.fd
		/usr/share/AAVMF/AAVMF_VARS.fd
		/usr/share/edk2/aarch64/QEMU_VARS-pflash.raw
		/opt/homebrew/share/qemu/edk2-arm-vars.fd
		/usr/local/share/qemu/edk2-arm-vars.fd
	"
	NETBOOT_URL="http://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi"
	;;
*)
	die "Unsupported architecture: $ARCH"
	;;
esac

# Find EDK2 firmware code
EFI_CODE=""
for candidate in $EFI_CODE_CANDIDATES; do
	if [ -f "$candidate" ]; then
		EFI_CODE="$candidate"
		break
	fi
done
[ -n "$EFI_CODE" ] || die "UEFI firmware code not found. Install qemu or ovmf/aavmf package."

# Find EDK2 firmware vars
EFI_VARS_TEMPLATE=""
for candidate in $EFI_VARS_CANDIDATES; do
	if [ -f "$candidate" ]; then
		EFI_VARS_TEMPLATE="$candidate"
		break
	fi
done
[ -n "$EFI_VARS_TEMPLATE" ] || die "UEFI firmware vars not found. Install qemu or ovmf/aavmf package."

command -v "$QEMU_BIN" > /dev/null 2>&1 || die "$QEMU_BIN not found in PATH"

if $NETBOOT; then
	EFI_VARS="/tmp/qemu-efi-vars-$ARCH.fd"
	cp "$EFI_VARS_TEMPLATE" "$EFI_VARS"

	QEMU_CMD="$QEMU_BIN \
		-M $QEMU_MACHINE \
		-cpu $QEMU_CPU \
		-m 512M \
		-nographic \
		-device virtio-rng-pci \
		-drive if=pflash,format=raw,readonly=on,file=$EFI_CODE \
		-drive if=pflash,format=raw,file=$EFI_VARS \
		-nic user,bootfile=$NETBOOT_URL \
		-fw_cfg name=opt/org.tianocore/IPv4PXESupport,string=no \
		-fw_cfg name=opt/org.tianocore/IPv6PXESupport,string=no"

	echo "Starting QEMU (${QEMU_BIN}) — UEFI HTTP boot from $NETBOOT_URL"
	echo "  UEFI code : $EFI_CODE"
	echo "  UEFI vars : $EFI_VARS"
	echo ""
	echo "Command: $QEMU_CMD"
	echo ""

	exec $QEMU_CMD
else
	usage
fi
