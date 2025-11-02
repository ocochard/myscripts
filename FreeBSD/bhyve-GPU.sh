#!/bin/sh
# Use case: Remote access (with Sunshine/Moonlight) to a MS Windows 11 VM
# using the GPU passthrough
# Scripted version of this great guide:
# http://www.paidbsd.org/blog/?1-bhyve_GPU_PT_setup.md
# https://github.com/churchers/vm-bhyve/wiki/Running-Windows
# Requiere a Windows 11 ISO as a first start
# - Auto detect CPU (Intel/AMD)
# - Auto detect and extract BIOS (for AMD GPU)
# - Using a TPM emulator isn't enough to work with MS Windows
#   https://github.com/stefanberger/swtpm/issues/1069
#   same symptom: From the edk2 EFI setup, in Device Manager, there is no
#   "TCG2 Configuration" menu
# TO DO:
# Need to check for any X running, or daemon like seatd, slim, etc.
# nvme emulation error (while booting from USB disk):
# nvme_opc_write_read command would exceed LBA range(slba=0x1 nblocks=0x21)
# And windows installer display a 16K disk only
set -eu
SUDO=sudo
vm_name=windows
vm_cpus=8
vm_ram=16         # in G
vm_zvol_name="zroot/vm_${vm_name}"
vm_zvol_size=150  # in G
vm_vnc_pwd=password
threads=$(nproc)
tmpdir=/tmp/bhyve_gpu
data=${tmpdir}/data
zpool=""
gpu_pci=""
gpu_rom=""
gpu_vendor=""     # vendor (Intel, AMD, Nvidia)
# Need to load previous data: gpu_pci, gpu_rom, zpool
# As example, the GPU PCI detection can run only once
# because once bind.sh is executed, thi PCI will be detached, so not visible
if [ -r ${data} ]; then
  . ${data}
fi

die() {
  echo -n "EXIT: " >&2
  echo "$@" >&2
  exit 1
}

usage() {
  echo "$0 Windows.iso"
  echo "You can download MS Windows iso file here:"
  echo "https://www.microsoft.com/en-us/software-download/windows11"
  exit 0
}

is_iso() {
  local file=$1
  if file ${file} | grep -q 9660; then
    return 0
  else
    return 1
  fi
}

bhyve_destroy() {
  if [ -e /dev/vmm/$vm_name ]; then
    ${SUDO} bhyvectl --destroy --vm $vm_name
  fi
}

bhyve_run() {

  # Bind the GPU's PCI device to the ppt driver (live: without editing loader.conf)
  # Need to avoid to return failure if already bound to ppt
  pptdevs="${gpu_pci}"
  ${SUDO} pptdevs=$pptdevs sh "${tmpdir}/bind.sh" || true

  # CPU binding
  threads_per_core=$(sysctl -n kern.smp.threads_per_core)
  cores=$(( threads / threads_per_core ))
  if [ ${threads_per_core} -gt 1 ]; then
    echo "HT on"
  fi

  if [ -c /dev/tpm0 ]; then
    tpm="-l tpm,passthru,/dev/tpm0"
  else
    tpm=""
    #tpm="-l tpm,swtpm,/var/run/swtpm/tpm"
  fi
  if [ "${gpu_vendor}" == "AMD" ]; then
    gpu="-s 1:0,passthru,${gpu_pci},rom=${gpu_rom}"
  else
    gpu="-s 1:0,passthru,${gpu_pci}"
  fi
  trap bhyve_destroy INT EXIT
  bhyve_destroy
  # -D Destroy the VM on guest initiated power-off
  # -S Wire guest memory (mandatory with passthru)
  # -H Yield the virtual CPU thread when a HLT instruction is detected
  # -w Ignore accesses to unimplemented Model Specific Registers (MSRs)
  # -l tpm,passthru
  # fbuf, vnc wait is important to catch the Windows CD message:
  # "Press any key to boot from CD or DVD..."
  # - virtio-net devices can be in any slot
  ${SUDO} bhyve -DSHw \
    -c 8 -m 16g \
    -l bootrom,/usr/local/share/edk2-bhyve/BHYVE_UEFI_CODE.fd,${tmpdir}/BHYVE_UEFI_VARS.fd \
    -s 0,hostbridge \
    ${gpu} \
    -s 2,nvme,/dev/zvol/${vm_zvol_name},bootindex=1 \
    -s 3,ahci-cd,${win_iso} \
    -s 4,ahci-cd,${virtio_iso} \
    -s 5,virtio-net,tap0 \
    -s 6:0,fbuf,tcp=0.0.0.0:5900,w=1920,h=1080,password=${vm_vnc_pwd},wait \
    -s 30,xhci,tablet \
    ${tpm} \
    -s 31,lpc -l com1,/dev/nmdm1A \
    $vm_name
}

if [ $# -lt 1 ]; then
  usage
else
  win_iso=$1
fi

echo "************************************************"
echo "* Stop all graphical utility (X11, seatd, etc.)"
echo "* On your PC, switch to virtual console 2 (Alt+F2) to avoid any screen update"
echo "*************"

mkdir -p ${tmpdir}
is_iso ${win_iso} || die "File ${win_iso} is not an ISO file"

if [ -z "${gpu_pci}" ]; then
  # Detecting GPU PCI ID
  # From this line:
  # $ pciconf -l | grep vgapci
  # vgapci0@pci0:1:0:0:     class=0x030000 rev=0xd5 hdr=0x00 vendor=0x1002 device=0x1900 subvendor=0x1002 subdevice=0x0124
  # Need to extract GPU vendore and PCI in form of 1/0/1
  pci=$(pciconf -l | awk '/vgapci/ {print $1}')
  vendor=$(pciconf -lv ${pci} | awk '/^[[:blank:]]+vendor/{gsub(/\x27/, ""); print $3}')
  case "${vendor}" in
    "Intel") gpu_vendor=Intel ;;
    "Advanced") gpu_vendor=AMD ;;
    *) gpu_vendor="" ;;
  esac
  gpu_pci=$(pciconf -l | awk '/vgapci/ {
    # Remove the prefix "vgapci0@pci0:"
    gsub(/^vgapci0@pci0:/, "", $1);
    # Remove the trailing ":"
    sub(/:$/, "", $1);
    # Replace remaining colons with slashes
    gsub(/:/, "/", $1);
    print $1
  }')

  if [ -z "${gpu_pci}" ]; then
    die "Did not find or fail to parse vga PCI id"
  fi
  echo "gpu_pci=${gpu_pci}" > ${data}
fi

# BIOS extraction (only for AMD GPU)
if [ "${gpu_vendor}" == "AMD" ] && [ -z "${gpu_rom}" ]; then
  ${SUDO} pkg install -y acpica-tools
  cd ${tmpdir}
  # specifying a full path here because of a name collision in $PATH
  # XXX What's this collision about???
  ${SUDO} /usr/local/bin/acpidump -b
  if [ -r ${tmpdir}/vfct.dat ]; then
     die "No vfct.dat file extracted with acpidump"
  fi
  fetch -o ${tmpdir}/vbios_vfct_file.c https://raw.githubusercontent.com/9vlc/ptnotes/refs/heads/main/progs/vbios_dump/vbios_vfct_file.c
  cc ${tmpdir}/vbios_vfct_file.c -o ${tmpdir}/vbios_vfct_file
  ${tmpdir}/vbios_vfct_file ${tmpdir}/vfct.dat
  gpu_rom=$(ls ${tmpdir}/*bin)
  echo "gpu_rom=${gpu_rom}" >> ${tmpdir}/data

  if file -b ${gpu_rom} | grep -q BIOS; then
    echo "Valid BIOS found"
  else
    echo "Warning: Non valid BIOS ?"
  fi
fi
# VirtIO drivers
# https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio
virtio_iso=${tmpdir}/virtio-win.iso
if ! [ -f ${virtio_iso} ]; then
  fetch -o ${tmpdir}/virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso
fi
is_iso ${virtio_iso} || die "File ${virtio_iso} is not an ISO file"


# Download bind script and its helper library
for s in bind.sh helpers.in;do
  if ! [ -f ${tmpdir}/$s ]; then
    fetch -o ${tmpdir}/$s https://raw.githubusercontent.com/9vlc/ptnotes/refs/heads/main/scripts/pci/$s
  fi
done


# ZFS dataset
# Search the first pool with enough disk space
# XXX Need to prevent to run that each time
if [ -z "${zpool}" ]; then
zpool list -H -po name,free | while read -r pool_name pool_free; do
  echo "Looking for enough free space in ${pool_name}"
  if [ "${pool_free}" -gt $(( vm_zvol_size * 1073741824 )) ]; then
    echo "Using ${pool_name} to store the VM"
    zpool=${pool_name}
    echo "zpool=${zpool}" >> ${tmpdir}/data
    break
  fi
done
fi
#if [ -z "${zpool}" ]; then
#  die "Failed to find a zpool (XXX: Need to switch to simple file)"
#fi

if ! zfs get -H -o value volsize ${vm_zvol_name}; then
  ${SUDO} zfs create -V ${vm_zvol_size} ${vm_zvol_name}
fi

if [ ${vm_cpus} -gt ${threads} ]; then
  die "VM should not have more CPUs (${vm_cpus}) than availables threads (${threads})"
fi

# XXX Same for RAM

# Need UEFI boot
if ! pkg info -q bhyve-firmware; then
  echo "Installing EFI firmware for bhyve"
  ${SUDO} pkg install -y bhyve-firmware
fi

# XXX No idea if Windows tried to store data in EUFI
if ! [ -w ${tmpdir}/BHYVE_UEFI_VARS.fd ]; then
  cp /usr/local/share/edk2-bhyve/BHYVE_UEFI_VARS.fd ${tmpdir}/
fi

# If this running host doesn't have a TPM, we will need to provide a
# softwate emulation
if ! kldstat -qn tpm.ko; then
  ${SUDO} kldload tpm
fi
if ! [ -c /dev/tpm0 ]; then
  echo "No TPM device found, and emulation with sysutils/swtpm not supported by MS Windows"
  echo "So for your Windows installation, once in the first install menu (language):"
  echo "Shift + F10, will open command line"
  echo "regedit"
  echo "HKEY_LOCAL_MACHINE\SYSTEM\Setup"
  echo "Create a new key (folder) named LabConfig"
  echo "Inside this LabConfig folder create a new Dword32bits named BypassTPMCheck and set it to 1"
  echo "Save and exit command line"
  #if ! pkg info -q sysutils/swtpm; then
  #  ${SUDO} pkg install -y sysutils/swtpm
  #fi
  #if ! service -q swtpm status; then
  #  echo "Enable and start swtpm service"
  #  ${SUDO} service swtpm enable
  #  ${SUDO} service swtpm start
  #fi
fi

# AMD CPU needs hw.vmm.amdvi enabled
if sysctl -n hw.model | grep -q AMD; then
  echo "CPU: AMD detected"
  # Need to enable IOMMU (AMD-VI)
  if ! grep -q 'hw.vmm.amdvi.enable' /boot/loader.conf; then
    echo "CPU: Need to enable hw.vmm.amdvi.enable"
    (
    echo '# Enable IOMMU (PCI passthrough) for AMD'
    echo 'hw.vmm.amdvi.enable="1"'
    ) | ${SUDO} tee -a /boot/loader.conf
  fi
  if kldstat -qm vmm; then
    # vmm already loaded, but was hw.vmm.amdvi already enabled ?
    if [ $(sysctl -n hw.vmm.amdvi.enable) -eq 0 ]; then
      echo "vmm.ko loaded and hw.vmm.amdvi.enable not enabled"
      die "You need to stop all VMs, unload vmm and reload it"
    fi
  fi
fi

# Serial is useless for Windows, but useful for the UEFI shell
if ! kldstat -qm nmdm; then
  ${SUDO} kldload nmdm
fi

bhyve_run
echo "Started, open a VNC to port 5900 with "${vm_vnc_pwd}" to start the VM, then once instructed press a key to boot from CD/DVD for the first install"
