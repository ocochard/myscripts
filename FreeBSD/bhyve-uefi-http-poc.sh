#!/usr/local/bin/bash
#
# Boot a stock FreeBSD memstick under bhyve by UEFI HTTP boot.
#
# The firmware does the HTTP fetch itself: DHCP hands out a boot URI, the
# guest's HttpDxe pulls ipxe.efi over HTTP, and iPXE then chainloads the
# patched loader.efi which fetches the memstick -- also over HTTP -- into
# RAM and boots it.  Nothing is typed at any prompt.
#
# This is the bhyve counterpart to ./qemu-uefi-inloader-poc.sh and boots the
# same official published image, unmodified.  The qemu script leans on SLIRP
# for DHCP, TFTP and outbound NAT, so its guest fetches the loader and the
# memstick straight from their public homes.  bhyve has none of that, so the
# plumbing is built here: a tap on an isolated bridge, dnsmasq for DHCP, and
# a local HTTP server.  The bridge is deliberately left with no route
# off-host (NAT would mean a pf change on this host and buys nothing), so
# both payloads are STAGED ON THIS HOST first -- fetched once into $CACHE,
# then re-served locally.  Repeat runs cost no download and the guest needs
# no internet access.
#
# The image stays compressed all the way into the guest.  The patched
# loader sniffs the format in the first downloaded chunk and streams it
# through its own decompressor (stand/efi/loader/decompress.c: xz, gzip,
# zstd), so the published .img.xz is handed over as-is -- do not unxz it.
# iPXE itself has no decompressor, but it never sees the payload here; that
# constraint belongs to the older memdisk_uefi route (./iPXE.md sec.7e).
#
# REQUIRES a patched bhyve edk2.  Stock sysutils/edk2 CANNOT do this, and
# cannot PXE either: the NetworkPkg modules are in its firmware volume but
# none of them dispatch.  Every NetworkPkg depex needs EFI_RNG_PROTOCOL,
# whose only Bhyve producer is VirtioRngDxe -- and bhyve has no virtio-rng
# device.  TcpDxe additionally needs EFI_HASH2_SERVICE_BINDING_PROTOCOL from
# SecurityPkg/Hash2DxeCrypto, which OvmfPkgX64 ships but the Bhyve platform
# omits; without TcpDxe there is no HttpServiceBinding and HttpBootDxe never
# binds, so BDS offers only PXEv4/v6 entries and UefiPxeBcDxe tries to TFTP
# the http:// URI (PXE-E99).

# Patch here: https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=298499

#
# The four changes needed (see the ports patches referenced below):
#   NETWORK_HTTP_BOOT_ENABLE=TRUE, NETWORK_IP6_ENABLE=TRUE,
#   + SecurityPkg/RandomNumberGenerator/RngDxe/RngDxe.inf
#   + SecurityPkg/Hash2DxeCrypto/Hash2DxeCrypto.inf
# With those, BDS auto-creates "UEFI HTTPv4" with a /Uri() node and boots.
#
# TLS is NOT needed for plain http:// -- NETWORK_TLS_ENABLE only adds https://.
# Point -f at your patched build; the script sanity-checks for HttpDxe before
# booting and tells you to use -T (TFTP) if it is missing.
#
# A local HTTP-enabled build lives in ~/edk2-httpboot (see the ports patch
# sysutils/edk2/files/patch-OvmfPkg_Bhyve_BhyveX64.dsc), and the default -f
# points at its BHYVE_CODE.fd -- the artifact booted end to end on 2026-09-15.
# That directory holds several builds; if you point -f elsewhere, boot it once
# and watch for "Start HTTP Boot over IPv4" before trusting it.  fwcheck below
# only proves HttpDxe is PRESENT, which is not the same as it dispatching.
#
# EXPECT TWO FAILURES BEFORE IT WORKS.  BDS walks the boot order, and the
# PXE entries come first:
#
#   >>Start PXE over IPv4 ... NBP filesize is 0 Bytes
#   PXE-E23: Client received TFTP error from server.
#   BdsDxe: failed to load Boot0001 "UEFI PXEv4 ...": Not Found
#   >>Start PXE over IPv6 ... PXE-E16: No valid offer received.
#   BdsDxe: failed to load Boot0002 "UEFI PXEv6 ...": Not Found
#   >>Start HTTP Boot over IPv4 ....      <-- this is the one that works
#
# Those two are HARMLESS and cost a few seconds.  UefiPxeBcDxe gets the offer
# first and TFTPs the http:// URI, which cannot work (dnsmasq logs the literal
# "http://host:port/ipxe.efi" as a missing TFTP file); BDS then reaches
# Boot0003 "UEFI HTTPv4", HttpBootDxe binds, and the boot proceeds.  Do not
# chase the PXE-E23/PXE-E16 lines -- they are not the failure.
#
# Requires: dnsmasq, ipxe, root.

set -euo pipefail

# Same official 15.1-RELEASE memstick as ./qemu-uefi-inloader-poc.sh.  It is
# published only as .img.xz and is handed to the guest that way (see above).
# Override with IMAGE= for another memstick, e.g. a 16.0 snapshot (snapshots
# expire, so the date needs bumping):
#   snap=FreeBSD-16.0-CURRENT-amd64-20260824-74019bc3ea91-288532
#   IMAGE=https://download.freebsd.org/ftp/snapshots/ISO-IMAGES/16.0/$snap-mini-memstick.img.xz
# A local file works too and is served as-is.
IMAGE=${IMAGE:-https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-amd64-mini-memstick.img.xz}
# Stock /usr/local/share/uefi-firmware/BHYVE_UEFI.fd is PXE/TFTP-only (use -T
# with it). Default to the local HTTP-capable build when it is present -- and
# specifically to the artifact measured to dispatch HttpBootDxe (see above).
# sudo resets HOME to /root, so $HOME/edk2-httpboot would silently miss and
# fall back to the PXE-only stock firmware. Use the INVOKING user's home.
_home=$HOME
[ -n "${SUDO_USER:-}" ] && _home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
_home=${_home:-$HOME}
for _fw in "$_home/edk2-httpboot/BHYVE_CODE.fd" \
           /usr/local/share/uefi-firmware/BHYVE_UEFI.fd; do
    [ -f "$_fw" ] && { FIRMWARE=${FIRMWARE:-$_fw}; break; }
done
FIRMWARE=${FIRMWARE:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
LOADER=${LOADER:-https://people.freebsd.org/~olivier/iPXE/loader.x64.efi}
IPXE=${IPXE:-/usr/local/share/ipxe/ipxe.efi-x86_64}
# Downloads are staged here and reused across runs; the workdir is not a
# cache because it is wiped on exit.
CACHE=${CACHE:-/var/tmp/bhyve-httpboot-cache}

VM=${VM:-httpboot}
CPUS=${CPUS:-2}
MEM=${MEM:-8G}          # the image is decompressed into RAM: 647MB for the 15.1 mini-memstick, plus headroom
BRIDGE=${BRIDGE:-vm-thrash-1}
TAP=${TAP:-}
HOSTIP=${HOSTIP:-10.99.0.1}
NETMASK=${NETMASK:-255.255.255.0}
DHCPRANGE=${DHCPRANGE:-10.99.0.10,10.99.0.100}
HTTPPORT=${HTTPPORT:-8080}
MODE=${MODE:-http}
ATTACH=${ATTACH:-0}
CONSOLE=${CONSOLE:-stdio}
KEEP=0

usage() {
    cat <<EOF
Usage: $0 [-i image] [-f firmware.fd] [-l loader_url] [-n vmname]
          [-c cpus] [-m mem] [-b bridge] [-t tap] [-p httpport]
          [-C cachedir] [-T] [-a] [-N] [-k]

  -i  memstick URL or local file  (default: the official 15.1 mini-memstick)
  -f  bhyve UEFI firmware         (default: $FIRMWARE)
  -l  patched loader.efi URL/path (default: $LOADER)
  -n  VM name                     (default: $VM)
  -c  vCPUs                       (default: $CPUS)
  -m  guest memory                (default: $MEM; the image is decompressed
                                   into RAM, 647MB for the 15.1 memstick)
  -b  bridge to attach to         (default: $BRIDGE)
  -t  tap device                  (default: auto-allocate)
  -p  HTTP port on the host       (default: $HTTPPORT)
  -C  download cache directory    (default: $CACHE)
  -T  TFTP/PXE instead of HTTP    (works with stock edk2, no HttpDxe needed)
  -a  attach the image as a local virtio-blk disk too (debug aid; needs an
      uncompressed, 512-aligned local image -- not the published .img.xz)
  -N  console on nmdm instead of stdio (headless/scripted runs;
      connect with: cu -l /dev/nmdm-$VM-B)
  -k  keep the workdir on exit (for inspecting dnsmasq/httpd logs)

Environment variables of the same name may be used instead of the flags.
Console is on stdio; the VM is destroyed and the network torn down on exit.
EOF
    exit 1
}

while getopts "i:f:l:n:c:m:b:t:p:C:TaNkh" opt; do
    case "$opt" in
        i) IMAGE=$OPTARG ;;
        f) FIRMWARE=$OPTARG ;;
        l) LOADER=$OPTARG ;;
        n) VM=$OPTARG ;;
        c) CPUS=$OPTARG ;;
        m) MEM=$OPTARG ;;
        b) BRIDGE=$OPTARG ;;
        t) TAP=$OPTARG ;;
        p) HTTPPORT=$OPTARG ;;
        C) CACHE=$OPTARG ;;
        T) MODE=tftp ;;
        a) ATTACH=1 ;;
        N) CONSOLE=nmdm ;;
        k) KEEP=1 ;;
        *) usage ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$FIRMWARE" ]   || { echo "no such firmware: $FIRMWARE" >&2; exit 1; }
[ -f "$IPXE" ]       || { echo "no such ipxe: $IPXE (pkg install ipxe)" >&2; exit 1; }
command -v dnsmasq >/dev/null || { echo "dnsmasq not installed" >&2; exit 1; }

case "$IMAGE" in
    http://*|https://*) ;;
    *) [ -f "$IMAGE" ] || { echo "no such image: $IMAGE" >&2; exit 1; } ;;
esac

# --- firmware capability check -------------------------------------------
# The DXE volume is LZMA-compressed and the driver names are UTF-16LE, so a
# plain "strings | grep" on the .fd is a guaranteed false negative.
# Decompress first, then search UTF-16.
#
# CAVEAT (measured 2026-09-14): this is a heuristic, not proof.  Some driver
# names appear as UI strings in the config menu even when the driver is NOT
# built in -- stock bhyve firmware yields one UTF-16 hit for each of Ip6Dxe,
# Dhcp6Dxe, Udp6Dxe and Mtftp6Dxe despite NETWORK_IP6_ENABLE=FALSE.  It is
# reliable for HttpDxe (0 hits stock, 2 hits with HTTP boot enabled), which
# is all this check uses it for.  To prove a module is really present, match
# its FILE_GUID against Build/.../FV/DXEFV.Fv.txt in the build tree, or use
# sysutils/UEFITool on a shipped .fd.
fwcheck() {
    python3 - "$1" "$2" <<'PYEOF'
import lzma, sys
data = open(sys.argv[1], 'rb').read()
blob = b''
for i in range(len(data) - 13):
    if data[i] == 0x5d and data[i+1:i+3] == b'\x00\x00':
        try:
            out = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE) \
                     .decompress(data[i:], 200_000_000)
            if len(out) > 100000:
                blob += out
        except Exception:
            pass
sys.exit(0 if (data + blob).count(sys.argv[2].encode('utf-16-le')) else 1)
PYEOF
}

if [ "$MODE" = http ]; then
    if ! fwcheck "$FIRMWARE" HttpDxe; then
        cat >&2 <<EOF
$FIRMWARE contains no HttpDxe: this firmware cannot UEFI HTTP boot.
Stock sysutils/edk2 bhyve firmware is PXE/TFTP-only.
Either pass -f <your HTTP-enabled build>, or run with -T to use TFTP.
EOF
        exit 1
    fi
    echo "==> firmware has HttpDxe: HTTP boot"
else
    echo "==> TFTP/PXE mode"
fi

WORK=$(mktemp -d /tmp/bhyve-httpboot.XXXXXX)
served=$WORK/served
mkdir -p "$served"
# dnsmasq drops privileges to "nobody" and then has to traverse these to
# read tftp-root; mktemp -d makes them 0700, which it cannot enter.
chmod 755 "$WORK" "$served"

# --- network -------------------------------------------------------------
kldload -n vmm if_tap if_bridge 2>/dev/null || true
sysctl -q net.link.tap.up_on_open=1

ifconfig "$BRIDGE" >/dev/null 2>&1 || ifconfig "$BRIDGE" create
if [ -z "$TAP" ]; then
    TAP=$(ifconfig tap create)
    TAP_CREATED=1
else
    ifconfig "$TAP" >/dev/null 2>&1 || { ifconfig "$TAP" create; TAP_CREATED=1; }
fi
TAP_CREATED=${TAP_CREATED:-0}

ifconfig "$BRIDGE" addm "$TAP" 2>/dev/null || true
ifconfig "$TAP" up
# Address the bridge so dnsmasq and the HTTP server are reachable from the guest.
ifconfig "$BRIDGE" inet "$HOSTIP" netmask "$NETMASK" alias 2>/dev/null || true
ifconfig "$BRIDGE" up

cleanup() {
    set +e
    [ -n "${HTTPD_PID:-}" ] && kill "$HTTPD_PID" 2>/dev/null
    [ -n "${DNSMASQ_PID:-}" ] && kill "$DNSMASQ_PID" 2>/dev/null
    bhyvectl --destroy --vm="$VM" 2>/dev/null
    ifconfig "$BRIDGE" deletem "$TAP" 2>/dev/null
    [ "$TAP_CREATED" = 1 ] && ifconfig "$TAP" destroy 2>/dev/null
    ifconfig "$BRIDGE" inet "$HOSTIP" -alias 2>/dev/null
    if [ "$KEEP" = 1 ]; then
        echo "workdir kept: $WORK" >&2
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT INT TERM

# --- payloads ------------------------------------------------------------
# Everything the guest boots is staged on this host: the bridge has no route
# off-host, so a URL the guest cannot reach is useless.  stage() resolves a
# URL-or-local-file into the served tree and echoes the local name.
#
# URLs are cached in $CACHE and reused; fetch -m only re-downloads when the
# remote is newer or the size differs, so a stale partial cannot be served as
# a whole image.  Local files are symlinked, so a multi-GB image is streamed
# from where it already lives rather than copied.
mkdir -p "$CACHE"
stage() {
    local src=$1 name=$2

    case "$src" in
        http://*|https://*)
            if [ -f "$CACHE/$name" ]; then
                echo "==> cached $name  ($(stat -f %z "$CACHE/$name") bytes)" >&2
            else
                echo "==> fetching $name from $src" >&2
            fi
            # -m: mirror-mode, keeps mtime so the size/time check works next run.
            fetch -m -o "$CACHE/$name" "$src" >&2 || {
                echo "failed to fetch $src" >&2
                echo "    the guest cannot reach it either (isolated bridge)," >&2
                echo "    so staging on this host is required." >&2
                return 1
            }
            ln -sf "$CACHE/$name" "$served/$name"
            ;;
        *)
            [ -f "$src" ] || { echo "no such file: $src" >&2; return 1; }
            ln -sf "$(realpath "$src")" "$served/$name"
            ;;
    esac
    echo "$name"
}

cp "$IPXE" "$served/ipxe.efi"
chmod 644 "$served/ipxe.efi"

# Keep the published name: the loader sniffs the compression format from the
# payload bytes, not the extension, but a truthful name keeps the boot log
# and the httpd log readable.
imgname=$(stage "$IMAGE" "$(basename "$IMAGE")") || exit 1
imgurl="http://$HOSTIP:$HTTPPORT/$imgname"

loadername=$(stage "$LOADER" loader.efi) || exit 1
loaderurl="http://$HOSTIP:$HTTPPORT/$loadername"

# iPXE looks for its script under two different names depending on how it was
# started, and which one applies is not worth guessing -- serve both.
#
#   autoexec.ipxe  the hardcoded "file:autoexec.ipxe" search path.  A
#                  network-chainloaded iPXE still tries this, relative to
#                  where it was itself loaded from.  Measured 2026-09-15:
#                  serving only boot.ipxe leaves iPXE searching
#                  "autoexec.ipxe... Not found (https://ipxe.org/2d0c618e)"
#                  once per protocol and dropping to its own prompt -- it
#                  never re-DHCPs for a filename at all.
#   boot.ipxe      handed out by dnsmasq to DHCP clients in the "iPXE"
#                  user-class (below); the standard trick that stops iPXE
#                  chainloading itself in a loop.
#
# Both names are the same file, so whichever path this iPXE build takes, it
# gets the same script.
cat > "$served/autoexec.ipxe" <<EOF
#!ipxe
dhcp
echo === chainloading patched loader.efi ===
chain $loaderurl memdisk=$imgurl
echo Boot failed, press a key
prompt
EOF

cp "$served/autoexec.ipxe" "$served/boot.ipxe"
chmod 644 "$served/autoexec.ipxe" "$served/boot.ipxe"
# The served entries are symlinks into $CACHE or to the original file; chmod
# the targets so the HTTP server (and dnsmasq's tftp, which drops to nobody)
# can read them.
chmod 644 "$CACHE"/* 2>/dev/null || true
chmod 755 "$CACHE" 2>/dev/null || true

# --- HTTP server ---------------------------------------------------------
# Serve with symlink following so disk.img streams straight from $IMAGE.
python3 -c "
import functools, http.server, os, sys
os.chdir(sys.argv[1])
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
http.server.ThreadingHTTPServer(('$HOSTIP', $HTTPPORT), h).serve_forever()
" "$served" >"$WORK/httpd.log" 2>&1 &
HTTPD_PID=$!
sleep 1
kill -0 "$HTTPD_PID" 2>/dev/null || { echo "HTTP server failed to start:" >&2; cat "$WORK/httpd.log" >&2; exit 1; }

# --- DHCP ----------------------------------------------------------------
# Two-stage: the firmware gets a boot URI (HTTP) or a filename (TFTP), and
# once iPXE itself is running it re-DHCPs with user-class "iPXE" and is sent
# boot.ipxe instead -- the standard trick that stops iPXE chainloading itself
# in a loop.  Belt and braces: iPXE may instead find autoexec.ipxe on its own
# without ever asking, which is what actually happens here (see above).
if [ "$MODE" = http ]; then
    # HttpBootDxe only treats an offer as an HTTP offer when the SERVER's
    # option 60 starts with "HTTPClient" (NetworkPkg/HttpBootDxe/HttpBootDhcp4.c,
    # CompareMem of 10 bytes vs DEFAULT_CLASS_ID_DATA). The firmware advertises
    # PXEClient:Arch:00007, so this must go out unconditionally -- gating it on
    # a client HTTPClient vendor class means UefiPxeBcDxe wins and TFTPs the
    # http:// URI instead (PXE-E99).
    firststage="dhcp-option=60,\"HTTPClient\"
dhcp-boot=tag:!ipxe,\"http://$HOSTIP:$HTTPPORT/ipxe.efi\""
else
    firststage="dhcp-boot=tag:!ipxe,ipxe.efi,,$HOSTIP"
fi

cat > "$WORK/dnsmasq.conf" <<EOF
port=0
interface=$BRIDGE
bind-interfaces
except-interface=lo0
dhcp-range=$DHCPRANGE,12h
dhcp-option=option:router,$HOSTIP
dhcp-userclass=set:ipxe,iPXE
$firststage
dhcp-boot=tag:ipxe,"http://$HOSTIP:$HTTPPORT/boot.ipxe"
enable-tftp
tftp-root=$served
log-dhcp
dhcp-authoritative
leasefile-ro
dhcp-leasefile=$WORK/leases
pid-file=$WORK/dnsmasq.pid
log-facility=$WORK/dnsmasq.log
EOF

dnsmasq -C "$WORK/dnsmasq.conf" -k >"$WORK/dnsmasq.stderr" 2>&1 &
DNSMASQ_PID=$!
sleep 1
kill -0 "$DNSMASQ_PID" 2>/dev/null || { echo "dnsmasq failed to start:" >&2; cat "$WORK/dnsmasq.stderr" "$WORK/dnsmasq.log" 2>/dev/null >&2; exit 1; }

# --- firmware vars -------------------------------------------------------
# Boot with a private writable VARS copy so the guest's boot order does not
# accumulate across runs: a custom build booted with no VARS has no writable
# variable store, and this firmware is built SECURE_BOOT_ENABLE=TRUE
# (authenticated variables), so it needs one.
#
# -f NAMES THE CODE IMAGE.  Only a _CODE.fd derived from that exact name is
# accepted as a substitute; a generic BHYVE_CODE.fd sitting in the same
# directory is NOT, because it may come from an unrelated build.  Getting
# this wrong silently boots firmware the user did not ask for -- measured
# 2026-09-15 in ~/edk2-httpboot, where BHYVE_UEFI.fd (21:44) and
# BHYVE_CODE.fd (22:13) are two different builds and -f BHYVE_UEFI.fd booted
# the latter.  Both happened to have the HTTP drivers, so the substitution
# was invisible; it would not have been if only one did.
vars=$WORK/vars.fd
dir=$(dirname "$FIRMWARE")

# A split build is <stem>_CODE.fd + <stem>_VARS.fd. Derive both from the
# stem of whatever -f was given and never mix stems.
stem=${FIRMWARE%.fd}
stem=${stem%_CODE}
if [ -f "${stem}_CODE.fd" ]; then
    code=${stem}_CODE.fd
else
    code=$FIRMWARE
fi

# VARS must come from the same stem. Fall back to a generic template only as
# a last resort, and say so: a mismatched variable store is a stale boot
# order (harmless but confusing -- BDS walks dead Boot#### entries first),
# not the wrong firmware.
varstpl=""
for v in "${stem}_VARS.fd" "${stem}.fd_VARS.fd"; do
    [ -f "$v" ] && { varstpl=$v; break; }
done
if [ -z "$varstpl" ]; then
    for v in "$dir/BHYVE_UEFI_VARS.fd" "$dir/BHYVE_VARS.fd"; do
        [ -f "$v" ] && {
            varstpl=$v
            echo "warning: no ${stem##*/}_VARS.fd; using $(basename "$v") from the" >&2
            echo "         same directory. If its boot order is stale you will see" >&2
            echo "         BDS try dead Boot#### entries before the HTTPv4 one." >&2
            break
        }
    done
fi

if [ -n "$varstpl" ]; then
    cp "$varstpl" "$vars"
    chmod u+w "$vars"
    bootrom="-l bootrom,$code,$vars"
    echo "==> firmware $code + vars $varstpl"
else
    echo "warning: no VARS template found next to $FIRMWARE; booting" >&2
    echo "         read-only. Secure-boot firmware may not boot this way." >&2
    bootrom="-l bootrom,$code"
fi

# --- run -----------------------------------------------------------------
bhyvectl --destroy --vm="$VM" 2>/dev/null || true

imgsize=$(stat -Lf %z "$served/$imgname" 2>/dev/null || echo "?")
echo "==> serving on $HOSTIP:$HTTPPORT   tap=$TAP bridge=$BRIDGE"
echo "    ipxe   http://$HOSTIP:$HTTPPORT/ipxe.efi"
echo "    loader $loaderurl"
echo "    image  $imgurl  ($imgsize bytes)"
echo "==> starting $VM (${CPUS} vcpu, ${MEM})"

# -a attaches the image as a real block device, which needs uncompressed
# bytes and a size that is a multiple of the logical sector size (bhyve's
# virtio-blk refuses anything else; pin 512 rather than letting it be
# inferred). The published memstick is .img.xz, so this is only for a local
# raw image.
diskarg=""
if [ "$ATTACH" = 1 ]; then
    attach=$(realpath "$served/$imgname")
    case "$imgname" in
        *.xz|*.gz|*.zst)
            echo "-a needs an uncompressed image; $imgname is compressed." >&2
            echo "    The guest boot itself is unaffected: the loader" >&2
            echo "    decompresses in RAM. Drop -a, or pass -i a raw image." >&2
            exit 1
            ;;
    esac
    if [ $(( $(stat -Lf %z "$attach") % 512 )) -ne 0 ]; then
        echo "-a: image size is not a multiple of 512; pad it first" >&2
        exit 1
    fi
    diskarg="-s 4:0,virtio-blk,$attach,sectorsize=512"
fi

# stdio needs a real terminal: under a redirected stdin (< /dev/null, CI,
# a pipeline) bhyve sees instant EOF on com1 and the guest never runs --
# it just idles with zero vm exits. Use -N there.
if [ "$CONSOLE" = nmdm ]; then
    kldload -n nmdm
    conarg="-l com1,/dev/nmdm-${VM}-A"
    echo "    console /dev/nmdm-${VM}-B  (cu -l /dev/nmdm-${VM}-B)"
else
    if [ ! -t 0 ]; then
        echo "warning: stdin is not a tty; bhyve com1,stdio will see EOF" >&2
        echo "         and the guest will not boot. Re-run with -N." >&2
    fi
    conarg="-l com1,stdio"
fi

# shellcheck disable=SC2086
bhyve -c "$CPUS" -m "$MEM" -A -H -P -u -w \
    $bootrom \
    -s 0:0,hostbridge \
    -s 1:0,lpc \
    -s 2:0,virtio-net,"$TAP" \
    $diskarg \
    $conarg \
    "$VM"
rc=$?
exit $rc
