#!/bin/sh
# Boot loader.efi memdisk= under qemu + edk2 + iPXE from an HTTP server that
# omits Content-Length, so iPXE sends no size hint and do_download_ramdisk()
# takes its "Nothing downloaded" path: a second decomp_fini().
#
#   ./loader_memdisk_zstd_fini_test.sh loader.efi [port]
#
# Prints the loader's download lines for zstd and xz, without and with
# Content-Length.  An unpatched loader panics "free: guard1 fail" (or prints
# "free: duplicate free") on zstd without length.
set -eu

LOADER=$(realpath "$1")
PORT=${2:-18089}
W=$(mktemp -d /tmp/zstd-fini.XXXXXX)
mkdir "$W/tftp"
cp "$LOADER" "$W/tftp/loader.efi"
dd if=/dev/zero bs=1m count=4 status=none | zstd -q -19 -c > "$W/tftp/img.zst"
dd if=/dev/zero bs=1m count=4 status=none | xz -c > "$W/tftp/img.xz"

# HTTP/1.0: /nolen/<f> ends the body at close with no Content-Length.
cat > "$W/srv.py" <<'EOF'
import os, socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[2]))); s.listen(4)
while True:
    c, a = s.accept()
    path = c.recv(4096).decode("latin1").split()[1]
    hdr = "HTTP/1.0 200 OK\r\nConnection: close\r\n"
    try:
        data = open(os.path.join(sys.argv[1], os.path.basename(path)), "rb").read()
        if not path.startswith("/nolen/"):
            hdr += "Content-Length: %d\r\n" % len(data)
        c.sendall((hdr + "\r\n").encode() + data)
    except OSError:
        c.sendall(b"HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    c.close()
EOF
python3 -I "$W/srv.py" "$W/tftp" "$PORT" &
SRV=$!
trap 'kill $SRV; rm -rf "$W"' EXIT
sleep 1

for url in nolen/img.zst nolen/img.xz img.zst img.xz; do
	esp=$W/esp
	rm -rf "$esp"; mkdir -p "$esp/EFI/BOOT"
	cp /usr/local/share/ipxe/ipxe.efi-x86_64 "$esp/EFI/BOOT/BOOTX64.EFI"
	printf '#!ipxe\ndhcp || shell\nchain tftp://10.0.2.2/loader.efi memdisk=http://10.0.2.2:%s/%s || shell\n' \
	    "$PORT" "$url" > "$esp/autoexec.ipxe"
	timeout -s KILL 60 qemu-system-x86_64 -m 2G \
	    -drive if=pflash,readonly=on,format=raw,file=/usr/local/share/qemu/edk2-x86_64-code.fd \
	    -drive file=fat:rw:$esp,format=raw,if=virtio \
	    -netdev user,id=net0,tftp=$W/tftp -device virtio-net-pci,netdev=net0 \
	    -nographic -no-reboot < /dev/null > "$W/log" 2>&1 || true
	echo "== $url"
	tr -d '\r' < "$W/log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' |
	    grep -a -E 'Downloading|We know|Downloaded|Nothing|free:|panic|EFI loader, Rev' |
	    head -8
done
