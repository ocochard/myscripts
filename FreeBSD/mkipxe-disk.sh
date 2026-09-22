#!/bin/sh
# Build the smallest bootable UEFI iPXE disk image.
#
# Layout: GPT, one EFI System Partition, nothing else.
#
#   disk.img
#   |- GPT primary
#   |- part1 type=efi, FAT
#   |    |- EFI/BOOT/BOOTX64.EFI   (the iPXE binary, a PE image)
#   |    \- autoexec.ipxe          (static IP + initrd + chain)
#   \- GPT secondary
#
# Why this works, in one line: UEFI's removable-media fallback path is
# \EFI\BOOT\BOOTX64.EFI, and EFI builds of iPXE auto-run autoexec.ipxe from
# the filesystem they booted from. No EMBED= rebuild, stock packaged binary.
# See ./iPXE.md sections 5e and 12.
#
# Sizing note: FAT12 is used by default because FAT16 requires at least 4085
# clusters, which forces the volume to ~2.1 MB regardless of payload size.
# FAT12 has no such floor, so the image ends up just larger than the binary.
# Both were verified to boot under edk2; use --fat16 if firmware objects.

set -eu

usage() {
	cat <<EOF
usage: ${0##*/} [options]

Output:
  -o, --output FILE     output image            (default: ipxe-uefi.img)

iPXE binary:
      --ipxe FILE       iPXE EFI binary to embed as EFI/BOOT/BOOTX64.EFI
                        (default: first match of ipxe.efi-x86_64 in
                        /usr/local/share/ipxe, then ipxe.efi in \$PWD)
      --arch ARCH       x86_64 | i386, picks the default binary and the
                        BOOT*.EFI name                (default: x86_64)

Network (static; all four are required unless --dhcp is given):
      --ip ADDR         IPv4 address
      --netmask MASK    netmask
      --gateway ADDR    default gateway
      --dns ADDR        DNS server
      --dhcp            use DHCP instead of a static address

Boot target:
      --initrd URL      initrd URL passed to iPXE 'initrd'
      --chain URL       URL passed to iPXE 'chain'
      --chain-args STR  arguments appended to the chain line
                        (default: "harddisk raw")

Script override:
      --script FILE     use FILE verbatim as autoexec.ipxe and ignore every
                        network and boot-target option above

Filesystem:
      --fat16           force FAT16 (larger, use if firmware rejects FAT12)
      --size KB         force FAT size in KiB instead of computing the minimum

Other:
  -n, --dry-run         print the generated autoexec.ipxe and exit
  -h, --help            this message

examples:
  ${0##*/} --ip 192.168.1.50 --netmask 255.255.255.0 \\
      --gateway 192.168.1.1 --dns 192.168.1.1 \\
      --initrd https://example/mini-memstick.img \\
      --chain https://example/loader.x64.efi

  ${0##*/} --ipxe ./my-ipxe.efi --dhcp --chain http://boot.netboot.xyz/ipxe/netboot.xyz.efi
EOF
}

output=ipxe-uefi.img
arch=x86_64
ipxe_bin=
ip= netmask= gateway= dns=
dhcp=no
initrd= chain=
chain_args="harddisk raw"
script_file=
fat_type=12
force_size=
dry_run=no

while [ $# -gt 0 ]; do
	case $1 in
	-o|--output)    output=$2; shift 2;;
	--ipxe)         ipxe_bin=$2; shift 2;;
	--arch)         arch=$2; shift 2;;
	--ip)           ip=$2; shift 2;;
	--netmask)      netmask=$2; shift 2;;
	--gateway)      gateway=$2; shift 2;;
	--dns)          dns=$2; shift 2;;
	--dhcp)         dhcp=yes; shift;;
	--initrd)       initrd=$2; shift 2;;
	--chain)        chain=$2; shift 2;;
	--chain-args)   chain_args=$2; shift 2;;
	--script)       script_file=$2; shift 2;;
	--fat16)        fat_type=16; shift;;
	--size)         force_size=$2; shift 2;;
	-n|--dry-run)   dry_run=yes; shift;;
	-h|--help)      usage; exit 0;;
	*) echo "${0##*/}: unknown option: $1" >&2; usage >&2; exit 1;;
	esac
done

case $arch in
x86_64) boot_name=BOOTX64.EFI;;
i386)   boot_name=BOOTIA32.EFI;;
*) echo "${0##*/}: unsupported arch: $arch (use x86_64 or i386)" >&2; exit 1;;
esac

for t in makefs mkimg; do
	command -v $t >/dev/null 2>&1 ||
		{ echo "${0##*/}: $t not found (FreeBSD base system)" >&2; exit 1; }
done

# --- locate the iPXE binary ------------------------------------------------
if [ -z "$ipxe_bin" ]; then
	for c in "/usr/local/share/ipxe/ipxe.efi-$arch" ./ipxe.efi; do
		[ -f "$c" ] && { ipxe_bin=$c; break; }
	done
fi
[ -n "$ipxe_bin" ] || {
	echo "${0##*/}: no iPXE binary found." >&2
	echo "  install net/ipxe (pkg install ipxe) or pass --ipxe FILE" >&2
	exit 1
}
[ -f "$ipxe_bin" ] || { echo "${0##*/}: no such file: $ipxe_bin" >&2; exit 1; }

# A non-PE image here is the single most common cause of a dead boot, and the
# firmware reports it only as a vague load error. Reject it now instead.
magic=$(dd if="$ipxe_bin" bs=1 count=2 2>/dev/null | tr -d '\0')
[ "$magic" = "MZ" ] || {
	echo "${0##*/}: $ipxe_bin is not a PE image (first bytes are not 'MZ')." >&2
	echo "  UEFI can only load PE images; a .ipxe script will not boot." >&2
	exit 1
}

# --- build autoexec.ipxe ---------------------------------------------------
workdir=$(mktemp -d "${TMPDIR:-/tmp}/mkipxe.XXXXXX")
trap 'rm -rf "$workdir"' EXIT INT TERM
esp=$workdir/esp
mkdir -p "$esp/EFI/BOOT"

if [ -n "$script_file" ]; then
	[ -f "$script_file" ] ||
		{ echo "${0##*/}: no such file: $script_file" >&2; exit 1; }
	cp "$script_file" "$esp/autoexec.ipxe"
else
	if [ "$dhcp" = no ]; then
		missing=
		[ -n "$ip" ]      || missing="$missing --ip"
		[ -n "$netmask" ] || missing="$missing --netmask"
		[ -n "$gateway" ] || missing="$missing --gateway"
		[ -n "$dns" ]     || missing="$missing --dns"
		[ -z "$missing" ] || {
			echo "${0##*/}: missing required option(s):$missing" >&2
			echo "  (or pass --dhcp, or supply your own --script FILE)" >&2
			exit 1
		}
	fi
	[ -n "$chain" ] || {
		echo "${0##*/}: --chain URL is required (or use --script FILE)" >&2
		exit 1
	}

	{
		echo '#!ipxe'
		if [ "$dhcp" = yes ]; then
			echo 'dhcp'
		else
			echo "set net0/ip $ip"
			echo "set net0/netmask $netmask"
			echo "set net0/gateway $gateway"
			echo "set net0/dns $dns"
			echo 'ifopen net0'
		fi
		[ -n "$initrd" ] && echo "initrd $initrd"
		if [ -n "$chain_args" ]; then
			echo "chain $chain $chain_args"
		else
			echo "chain $chain"
		fi
	} > "$esp/autoexec.ipxe"
fi

if [ "$dry_run" = yes ]; then
	cat "$esp/autoexec.ipxe"
	exit 0
fi

cp "$ipxe_bin" "$esp/EFI/BOOT/$boot_name"

# --- size the FAT volume ---------------------------------------------------
# makefs exits 0 and writes a zeroed, unbootable sector 0 when the volume is
# too small for the requested FAT type, so grow until the boot signature is
# actually present rather than trusting the exit status.
fat_valid() {
	[ "$(od -A n -t x1 -j 510 -N 2 "$1" 2>/dev/null | tr -d ' ')" = "55aa" ]
}

fat=$workdir/fat.img
payload_kb=$(du -A -k -s "$esp" | awk '{print $1}')

if [ -n "$force_size" ]; then
	rm -f "$fat"
	makefs -t msdos -o "fat_type=$fat_type,sectors_per_cluster=1" \
		-s "${force_size}k" "$fat" "$esp" >/dev/null 2>&1 || true
	fat_valid "$fat" || {
		echo "${0##*/}: --size ${force_size}k is too small for FAT$fat_type" >&2
		exit 1
	}
	size_kb=$force_size
else
	size_kb=$((payload_kb + 16))
	limit=$((payload_kb * 4 + 65536))
	built=no
	while [ $size_kb -le $limit ]; do
		rm -f "$fat"
		if makefs -t msdos -o "fat_type=$fat_type,sectors_per_cluster=1" \
			-s "${size_kb}k" "$fat" "$esp" >/dev/null 2>&1 &&
			fat_valid "$fat"; then
			built=yes
			break
		fi
		size_kb=$((size_kb + 16))
	done
	[ "$built" = yes ] || {
		echo "${0##*/}: could not build a valid FAT$fat_type up to ${limit}k" >&2
		exit 1
	}
fi

mkimg -s gpt -p "efi:=$fat" -o "$output"

fat_bytes=$(stat -f %z "$fat")
img_bytes=$(stat -f %z "$output")
printf '%s: %s\n' "${0##*/}" "$output"
printf '  iPXE binary : %s -> EFI/BOOT/%s (%s bytes)\n' \
	"$ipxe_bin" "$boot_name" "$(stat -f %z "$ipxe_bin")"
printf '  filesystem  : FAT%s, %s bytes\n' "$fat_type" "$fat_bytes"
printf '  image       : GPT + ESP, %s bytes (%s KiB)\n' \
	"$img_bytes" "$((img_bytes / 1024))"
echo
echo '  autoexec.ipxe:'
sed 's/^/    /' "$esp/autoexec.ipxe"
