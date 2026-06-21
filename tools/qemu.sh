#!/bin/sh
# QEMU launcher with optional netboot.xyz UEFI iPXE boot
set -eu

usage() {
	echo "Usage: ${0##*/} [-netboot]"
	echo "  -netboot  Download and boot netboot.xyz EFI image via UEFI iPXE"
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
		/usr/share/OVMF/OVMF_CODE.fd
		/usr/share/edk2/ovmf/OVMF_CODE.fd
		/opt/homebrew/share/qemu/edk2-x86_64-code.fd
		/usr/local/share/qemu/edk2-x86_64-code.fd
	"
	EFI_VARS_CANDIDATES="
		/usr/share/qemu/edk2-i386-vars.fd
		/usr/share/OVMF/OVMF_VARS.fd
		/usr/share/edk2/ovmf/OVMF_VARS.fd
		/opt/homebrew/share/qemu/edk2-i386-vars.fd
		/usr/local/share/qemu/edk2-i386-vars.fd
	"
	NETBOOT_URL="https://boot.netboot.xyz/ipxe/netboot.xyz.efi"
	EFI_BOOT_FILENAME="BOOTX64.EFI"
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
	NETBOOT_URL="https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi"
	EFI_BOOT_FILENAME="BOOTAA64.EFI"
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
	EFI_FILE="/tmp/netboot-$(uname -m).efi"
	EFI_IMG="/tmp/netboot-$(uname -m)-efi.img"
	EFI_VARS="/tmp/qemu-efi-vars-$(uname -m).fd"

	echo "Downloading $NETBOOT_URL ..."
	curl -fsSL -o "$EFI_FILE" "$NETBOOT_URL"

	echo "Building FAT32 boot image ..."
	# Create a 64MB zero-filled image
	dd if=/dev/zero of="$EFI_IMG" bs=1M count=64 2>/dev/null

	# Format and populate: macOS uses hdiutil, Linux uses mtools or losetup
	OS=$(uname -s)
	case "$OS" in
	Darwin)
		DISK=$(hdiutil attach -nomount "$EFI_IMG" | awk '{print $1}')
		diskutil eraseDisk FAT32 NETBOOT MBRFormat "$DISK" > /dev/null 2>&1
		MOUNT=$(diskutil info "${DISK}s1" | awk '/Mount Point/{print $3}')
		mkdir -p "$MOUNT/EFI/BOOT"
		cp "$EFI_FILE" "$MOUNT/EFI/BOOT/$EFI_BOOT_FILENAME"
		hdiutil detach "$DISK" > /dev/null 2>&1
		;;
	Linux)
		command -v mformat > /dev/null 2>&1 || die "mtools not found. Install mtools package."
		mformat -i "$EFI_IMG" -F -v NETBOOT ::
		mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
		mcopy -i "$EFI_IMG" "$EFI_FILE" "::/EFI/BOOT/$EFI_BOOT_FILENAME"
		;;
	*)
		die "Unsupported OS: $OS"
		;;
	esac

	cp "$EFI_VARS_TEMPLATE" "$EFI_VARS"

	echo "Starting QEMU (${QEMU_BIN}) with netboot.xyz ..."
	echo "  UEFI code : $EFI_CODE"
	echo "  UEFI vars : $EFI_VARS"
	echo "  Boot image: $EFI_IMG"
	echo ""
	echo "Command:"
	echo "  $QEMU_BIN \\"
	echo "    -M $QEMU_MACHINE \\"
	echo "    -cpu $QEMU_CPU \\"
	echo "    -m 512M \\"
	echo "    -nographic \\"
	echo "    -drive if=pflash,format=raw,readonly=on,file=$EFI_CODE \\"
	echo "    -drive if=pflash,format=raw,file=$EFI_VARS \\"
	echo "    -drive file=$EFI_IMG,format=raw,if=virtio \\"
	echo "    -net nic \\"
	echo "    -net user"
	echo ""

	exec "$QEMU_BIN" \
		-M "$QEMU_MACHINE" \
		-cpu "$QEMU_CPU" \
		-m 512M \
		-nographic \
		-drive if=pflash,format=raw,readonly=on,file="$EFI_CODE" \
		-drive if=pflash,format=raw,file="$EFI_VARS" \
		-drive file="$EFI_IMG",format=raw,if=virtio \
		-net nic \
		-net user
else
	usage
fi
