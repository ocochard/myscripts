# System info
## dmesg
```
---<<BOOT>>---
Copyright (c) 1992-2023 The FreeBSD Project.
Copyright (c) 1979, 1980, 1983, 1986, 1988, 1989, 1991, 1992, 1993, 1994
	The Regents of the University of California. All rights reserved.
FreeBSD is a registered trademark of The FreeBSD Foundation.
FreeBSD 15.0-CURRENT #8 main-n266813-4b92c7721dee: Mon Dec  4 20:34:36 CET 2023
    root@bigone:/usr/obj/usr/src/amd64.amd64/sys/GENERIC-NODEBUG amd64
FreeBSD clang version 16.0.6 (https://github.com/llvm/llvm-project.git llvmorg-16.0.6-0-g7cbf1a259152)
VT(efifb): resolution 800x600
CPU: AMD EPYC 7502P 32-Core Processor                (2495.45-MHz K8-class CPU)
  Origin="AuthenticAMD"  Id=0x830f10  Family=0x17  Model=0x31  Stepping=0
  Features=0x178bfbff<FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,APIC,SEP,MTRR,PGE,MCA,CMOV,PAT,PSE36,CLFLUSH,MMX,FXSR,SSE,SSE2,HTT>
  Features2=0x7ed8320b<SSE3,PCLMULQDQ,MON,SSSE3,FMA,CX16,SSE4.1,SSE4.2,MOVBE,POPCNT,AESNI,XSAVE,OSXSAVE,AVX,F16C,RDRAND>
  AMD Features=0x2e500800<SYSCALL,NX,MMX+,FFXSR,Page1GB,RDTSCP,LM>
  AMD Features2=0x75c237ff<LAHF,CMP,SVM,ExtAPIC,CR8,ABM,SSE4A,MAS,Prefetch,OSVW,IBS,SKINIT,WDT,TCE,Topology,PCXC,PNXC,DBE,PL2I,MWAITX,ADMSKX>
  Structured Extended Features=0x219c91a9<FSGSBASE,BMI1,AVX2,SMEP,BMI2,PQM,PQE,RDSEED,ADX,SMAP,CLFLUSHOPT,CLWB,SHA>
  Structured Extended Features2=0x400004<UMIP,RDPID>
  XSAVE Features=0xf<XSAVEOPT,XSAVEC,XINUSE,XSAVES>
  AMD Extended Feature Extensions ID EBX=0x18cf757<CLZERO,IRPerf,XSaveErPtr,RDPRU,MCOMMIT,WBNOINVD,IBPB,IBRS,STIBP,PREFER_IBRS,PPIN,SSBD>
  SVM: NP,NRIP,VClean,AFlush,DAssist,NAsids=32768
  TSC: P-state invariant, performance statistics
real memory  = 274869518336 (262136 MB)
avail memory = 267574231040 (255178 MB)
Event timer "LAPIC" quality 600
ACPI APIC Table: <AMD ETHANOLX>
FreeBSD/SMP: Multiprocessor System Detected: 64 CPUs
FreeBSD/SMP: 1 package(s) x 8 cache groups x 4 core(s) x 2 hardware threads
random: registering fast source Intel Secure Key RNG
random: fast provider: "Intel Secure Key RNG"
random: unblocking device.
ioapic0 <Version 2.1> irqs 0-23
ioapic1 <Version 2.1> irqs 24-55
ioapic2 <Version 2.1> irqs 56-87
ioapic3 <Version 2.1> irqs 88-119
ioapic4 <Version 2.1> irqs 120-151
Launching APs: 44 1 4 2 6 34 39 33 59 55 52 49 36 50 37 57 62 61 17 19 20 25 47 41 22 29 31 27 13 9 15 43 10 63 53 48 60 23 26 32 30 16 58 54 56 40 8 5 51 3 12 46 7 11 42 38 35 24 28 18 21 45 14
random: entropy device external interface
kbd0 at kbdmux0
efirtc0: <EFI Realtime Clock>
efirtc0: registered as a time-of-day clock, resolution 1.000000s
smbios0: <System Management BIOS> at iomem 0xa8d82000-0xa8d82017
smbios0: Version: 3.2
aesni0: <AES-CBC,AES-CCM,AES-GCM,AES-ICM,AES-XTS,SHA1,SHA256>
acpi0: <AMD>
acpi0: Power Button (fixed)
attimer0: <AT timer> port 0x40-0x43 irq 0 on acpi0
Timecounter "i8254" frequency 1193182 Hz quality 0
Event timer "i8254" frequency 1193182 Hz quality 100
atrtc0: <AT realtime clock> port 0x70-0x71 on acpi0
atrtc0: registered as a time-of-day clock, resolution 1.000000s
Event timer "RTC" frequency 32768 Hz quality 0
hpet0: <High Precision Event Timer> iomem 0xfed00000-0xfed003ff on acpi0
Timecounter "HPET" frequency 14318180 Hz quality 950
Event timer "HPET" frequency 14318180 Hz quality 350
Event timer "HPET1" frequency 14318180 Hz quality 350
Event timer "HPET2" frequency 14318180 Hz quality 350
Timecounter "ACPI-fast" frequency 3579545 Hz quality 900
acpi_timer0: <32-bit timer at 3.579545MHz> port 0x808-0x80b on acpi0
pcib0: <ACPI Host-PCI bridge> numa-domain 0 on acpi0
pci0: <ACPI PCI bus> numa-domain 0 on pcib0
pci0: <base peripheral, IOMMU> at device 0.2 (no driver attached)
pcib1: <ACPI PCI-PCI bridge> at device 7.1 numa-domain 0 on pci0
pci1: <ACPI PCI bus> numa-domain 0 on pcib1
pci1: <encrypt/decrypt> at device 0.2 (no driver attached)
pcib2: <ACPI PCI-PCI bridge> at device 8.1 numa-domain 0 on pci0
pci2: <ACPI PCI bus> numa-domain 0 on pcib2
pci2: <encrypt/decrypt> at device 0.2 (no driver attached)
pcib3: <ACPI Host-PCI bridge> numa-domain 1 on acpi0
pci3: <ACPI PCI bus> numa-domain 1 on pcib3
pci3: <base peripheral, IOMMU> at device 0.2 (no driver attached)
pcib4: <ACPI PCI-PCI bridge> at device 7.1 numa-domain 1 on pci3
pci4: <ACPI PCI bus> numa-domain 1 on pcib4
pci4: <encrypt/decrypt> at device 0.2 (no driver attached)
pcib5: <ACPI PCI-PCI bridge> at device 8.1 numa-domain 1 on pci3
pci5: <ACPI PCI bus> numa-domain 1 on pcib5
pci5: <encrypt/decrypt> at device 0.2 (no driver attached)
pcib6: <ACPI PCI-PCI bridge> at device 8.2 numa-domain 1 on pci3
pci6: <ACPI PCI bus> numa-domain 1 on pcib6
ahci0: <AMD KERNCZ AHCI SATA controller> mem 0xf6600000-0xf66007ff at device 0.0 numa-domain 1 on pci6
ahci0: AHCI v1.31 with 6 6Gbps ports, Port Multiplier supported with FBS
ahcich0: <AHCI channel> at channel 0 on ahci0
ahcich1: <AHCI channel> at channel 1 on ahci0
ahcich2: <AHCI channel> at channel 2 on ahci0
ahcich3: <AHCI channel> at channel 3 on ahci0
ahcich4: <AHCI channel> at channel 4 on ahci0
ahcich5: <AHCI channel> at channel 5 on ahci0
ahciem0: <AHCI enclosure management bridge> on ahci0
pcib7: <ACPI PCI-PCI bridge> at device 8.3 numa-domain 1 on pci3
pci7: <ACPI PCI bus> numa-domain 1 on pcib7
ahci1: <AMD KERNCZ AHCI SATA controller> mem 0xf6500000-0xf65007ff at device 0.0 numa-domain 1 on pci7
ahci1: AHCI v1.31 with 8 6Gbps ports, Port Multiplier supported with FBS
ahcich6: <AHCI channel> at channel 0 on ahci1
ahcich7: <AHCI channel> at channel 1 on ahci1
ahcich8: <AHCI channel> at channel 2 on ahci1
ahcich9: <AHCI channel> at channel 3 on ahci1
ahcich10: <AHCI channel> at channel 4 on ahci1
ahcich11: <AHCI channel> at channel 5 on ahci1
ahcich12: <AHCI channel> at channel 6 on ahci1
ahcich13: <AHCI channel> at channel 7 on ahci1
ahciem1: <AHCI enclosure management bridge> on ahci1
pcib8: <ACPI Host-PCI bridge> numa-domain 2 on acpi0
pci8: <ACPI PCI bus> numa-domain 2 on pcib8
pci8: <base peripheral, IOMMU> at device 0.2 (no driver attached)
pcib9: <ACPI PCI-PCI bridge> at device 7.1 numa-domain 2 on pci8
pci9: <ACPI PCI bus> numa-domain 2 on pcib9
pci9: <encrypt/decrypt> at device 0.2 (no driver attached)
pcib10: <ACPI PCI-PCI bridge> at device 8.1 numa-domain 2 on pci8
pci10: <ACPI PCI bus> numa-domain 2 on pcib10
pci10: <encrypt/decrypt> at device 0.1 (no driver attached)
pci10: <encrypt/decrypt> at device 0.2 (no driver attached)
xhci0: <AMD Starship USB 3.0 controller> mem 0xf2000000-0xf20fffff at device 0.3 numa-domain 2 on pci10
xhci0: 64 bytes context size, 64-bit DMA
usbus0 numa-domain 2 on xhci0
usbus0: 5.0Gbps Super Speed USB v3.0
pcib11: <ACPI PCI-PCI bridge> at device 8.2 numa-domain 2 on pci8
pci11: <ACPI PCI bus> numa-domain 2 on pcib11
ahci2: <AMD KERNCZ AHCI SATA controller> mem 0xf2300000-0xf23007ff at device 0.0 numa-domain 2 on pci11
ahci2: AHCI v1.31 with 1 6Gbps ports, Port Multiplier supported with FBS
ahcich14: <AHCI channel> at channel 0 on ahci2
pcib12: <ACPI Host-PCI bridge> port 0xcf8-0xcff numa-domain 3 on acpi0
pci12: <ACPI PCI bus> numa-domain 3 on pcib12
pci12: <base peripheral, IOMMU> at device 0.2 (no driver attached)
pcib13: <ACPI PCI-PCI bridge> at device 3.1 numa-domain 3 on pci12
pci13: <ACPI PCI bus> numa-domain 3 on pcib13
pcib14: <PCI-PCI bridge> at device 0.0 numa-domain 3 on pci13
pci14: <PCI bus> numa-domain 3 on pcib14
vgapci0: <VGA-compatible display> port 0x3000-0x307f mem 0xf9000000-0xf9ffffff,0xfa000000-0xfa01ffff at device 0.0 numa-domain 3 on pci14
pcib15: <ACPI PCI-PCI bridge> at device 3.2 numa-domain 3 on pci12
pci15: <ACPI PCI bus> numa-domain 3 on pcib15
nvme0: <Generic NVMe Device> mem 0xfa800000-0xfa803fff,0xfa804000-0xfa8040ff at device 0.0 numa-domain 3 on pci15
pcib16: <ACPI PCI-PCI bridge> at device 3.3 numa-domain 3 on pci12
pci16: <ACPI PCI bus> numa-domain 3 on pcib16
nvme1: <Generic NVMe Device> mem 0xfa700000-0xfa703fff,0xfa704000-0xfa7040ff at device 0.0 numa-domain 3 on pci16
pcib17: <ACPI PCI-PCI bridge> at device 3.5 numa-domain 3 on pci12
pci17: <ACPI PCI bus> numa-domain 3 on pcib17
igb0: <Intel(R) I210 (Copper)> port 0x2000-0x201f mem 0xfa600000-0xfa67ffff,0xfa680000-0xfa683fff at device 0.0 numa-domain 3 on pci17
igb0: EEPROM V3.25-0 eTrack 0x800005cb
igb0: Using 1024 TX descriptors and 1024 RX descriptors
igb0: Using 4 RX queues 4 TX queues
igb0: Using MSI-X interrupts with 5 vectors
igb0: Ethernet address: a0:42:3f:48:a9:38
igb0: netmap queues/slots: TX 4/1024, RX 4/1024
pcib18: <ACPI PCI-PCI bridge> at device 3.6 numa-domain 3 on pci12
pci18: <ACPI PCI bus> numa-domain 3 on pcib18
igb1: <Intel(R) I210 (Copper)> port 0x1000-0x101f mem 0xfa500000-0xfa57ffff,0xfa580000-0xfa583fff at device 0.0 numa-domain 3 on pci18
igb1: EEPROM V3.25-0 eTrack 0x800005cb
igb1: Using 1024 TX descriptors and 1024 RX descriptors
igb1: Using 4 RX queues 4 TX queues
igb1: Using MSI-X interrupts with 5 vectors
igb1: Ethernet address: a0:42:3f:48:a9:39
igb1: netmap queues/slots: TX 4/1024, RX 4/1024
pcib19: <ACPI PCI-PCI bridge> at device 7.1 numa-domain 3 on pci12
pci19: <ACPI PCI bus> numa-domain 3 on pcib19
pci19: <encrypt/decrypt> at device 0.2 (no driver attached)
pcib20: <ACPI PCI-PCI bridge> at device 8.1 numa-domain 3 on pci12
pci20: <ACPI PCI bus> numa-domain 3 on pcib20
pci20: <encrypt/decrypt> at device 0.2 (no driver attached)
xhci1: <AMD Starship USB 3.0 controller> mem 0xfa200000-0xfa2fffff at device 0.3 numa-domain 3 on pci20
xhci1: 64 bytes context size, 64-bit DMA
usbus1 numa-domain 3 on xhci1
usbus1: 5.0Gbps Super Speed USB v3.0
isab0: <PCI-ISA bridge> at device 20.3 numa-domain 3 on pci12
isa0: <ISA bus> numa-domain 3 on isab0
cpu0: <ACPI CPU> on acpi0
apei0: <ACPI Platform Error Interface> on acpi0
uart0: <16550 or compatible> port 0x3f8-0x3ff irq 4 flags 0x10 on acpi0
ns8250: UART FCR is broken
uart0: console (115200,n,8,1)
hwpstate0: <Cool`n'Quiet 2.0> on cpu0
Timecounter "TSC-low" frequency 1247656349 Hz quality 1000
Timecounters tick every 1.000 msec
ugen1.1: <AMD XHCI root HUB> at usbus1
ugen0.1: <AMD XHCI root HUB> at usbus0
uhub0 numa-domain 3 on usbus1
uhub0: <AMD XHCI root HUB, class 9/0, rev 3.00/1.00, addr 1> on usbus1
uhub1 numa-domain 2 on usbus0
uhub1: <AMD XHCI root HUB, class 9/0, rev 3.00/1.00, addr 1> on usbus0
ZFS filesystem version: 5
ZFS storage pool version: features support (5000)
ahciem0: Unsupported enclosure interface
(aprobe0:ahciem0:0:0:0): SEP_ATTN IDENTIFY. ACB: 67 ec 02 00 00 40 00 00 00 00 80 00
(aprobe0:ahciem0:0:0:0): CAM status: CCB request was invalid
(aprobe0:ahciem0:0:0:0): Error 22, Unretryable error
uhub1: 4 ports with 4 removable, self powered
uhub0: 4 ports with 4 removable, self powered
ahciem1: Unsupported enclosure interface
(aprobe0:ahciem1:0:0:0): SEP_ATTN IDENTIFY. ACB: 67 ec 02 00 00 40 00 00 00 00 80 00
(aprobe0:ahciem1:0:0:0): CAM status: CCB request was invalid
(aprobe0:ahciem1:0:0:0): Error 22, Unretryable error
nda0 at nvme0 bus 0 scbus17 target 0 lun 1
nda0: <WDC CL SN720 SDAQNTX-2T00-2000 10204122 20421C800286>
nda0: Serial Number 20421C800286
nda0: nvme version 1.3
nda0: 1953514MB (4000797360 512 byte sectors)
nda1 at nvme1 bus 0 scbus18 target 0 lun 1
nda1: <WDC CL SN720 SDAQNTX-2T00-2000 10204122 20421C800368>
nda1: Serial Number 20421C800368
nda1: nvme version 1.3
nda1: 1953514MB (4000797360 512 byte sectors)
Trying to mount root from zfs:zroot/ROOT/15.0-CURRENT-20231204.191947 []...
ugen1.2: <Aspeed USB Virtual Hub> at usbus1
uhub2 numa-domain 3 on uhub0
uhub2: <Aspeed USB Virtual Hub, class 9/0, rev 2.00/1.00, addr 1> on usbus1
ugen0.2: <Yubico YubiKey OTP+FIDO+CCID> at usbus0
ukbd0 numa-domain 2 on uhub1
ukbd0: <Yubico YubiKey OTP+FIDO+CCID, class 0/0, rev 2.00/5.27, addr 1> on usbus0
kbd1 at ukbd0
uhub2: 5 ports with 5 removable, self powered
ugen1.3: <OpenBMC OpenBMC Net> at usbus1
Root mount waiting for: usbus1
ugen1.4: <OpenBMC virtualinput> at usbus1
ukbd1 numa-domain 3 on uhub2
ukbd1: <HID Interface> on usbus1
kbd2 at ukbd1
ugen1.5: <GenesysLogic USB2.1 Hub> at usbus1
uhub3 numa-domain 3 on uhub0
uhub3: <GenesysLogic USB2.1 Hub, class 9/0, rev 2.10/93.07, addr 4> on usbus1
uhub3: MTT enabled
Root mount waiting for: usbus1
uhub3: 4 ports with 4 removable, self powered
ugen1.6: <GenesysLogic USB3.2 Hub> at usbus1
uhub4 numa-domain 3 on uhub0
uhub4: <GenesysLogic USB3.2 Hub, class 9/0, rev 3.20/93.07, addr 5> on usbus1
Root mount waiting for: usbus1
uhub4: 4 ports with 4 removable, self powered
Dual Console: Video Primary, Serial Secondary
driver bug: Unable to set devclass (class: ppc devname: (unknown))
ipmi0: <IPMI System Interface> port 0xca2,0xca3 on acpi0
ipmi0: KCS mode found at io 0xca2 on acpi
ipmi0: IPMI device rev. 0, firmware rev. 4.43, version 2.0, device support mask 0xbf
ipmi0: Number of channels 3
ipmi0: Attached watchdog
ipmi0: Establishing power cycle handler
TCP Hpts created 64 swi interrupt threads and bound 64 to NUMA domains
Attempting to load tcp_bbr
tcp_bbr is now available
amdsmn0: <AMD Family 17h System Management Network> numa-domain 0 on hostb0
amdsmn1: <AMD Family 17h System Management Network> numa-domain 1 on hostb8
amdsmn2: <AMD Family 17h System Management Network> numa-domain 2 on hostb16
amdsmn3: <AMD Family 17h System Management Network> numa-domain 3 on hostb24
amdtemp0: <AMD CPU On-Die Thermal Sensors> numa-domain 0 on hostb0
amdtemp1: <AMD CPU On-Die Thermal Sensors> numa-domain 1 on hostb8
amdtemp2: <AMD CPU On-Die Thermal Sensors> numa-domain 2 on hostb16
amdtemp3: <AMD CPU On-Die Thermal Sensors> numa-domain 3 on hostb24
intsmb0: <AMD FCH SMBus Controller> at device 20.0 numa-domain 3 on pci12
smbus0: <System Management Bus> numa-domain 3 on intsmb0
CPU: AMD EPYC 7502P 32-Core Processor                (2495.31-MHz K8-class CPU)
  Origin="AuthenticAMD"  Id=0x830f10  Family=0x17  Model=0x31  Stepping=0
  Features=0x178bfbff<FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,APIC,SEP,MTRR,PGE,MCA,CMOV,PAT,PSE36,CLFLUSH,MMX,FXSR,SSE,SSE2,HTT>
  Features2=0x7ed8320b<SSE3,PCLMULQDQ,MON,SSSE3,FMA,CX16,SSE4.1,SSE4.2,MOVBE,POPCNT,AESNI,XSAVE,OSXSAVE,AVX,F16C,RDRAND>
  AMD Features=0x2e500800<SYSCALL,NX,MMX+,FFXSR,Page1GB,RDTSCP,LM>
  AMD Features2=0x75c237ff<LAHF,CMP,SVM,ExtAPIC,CR8,ABM,SSE4A,MAS,Prefetch,OSVW,IBS,SKINIT,WDT,TCE,Topology,PCXC,PNXC,DBE,PL2I,MWAITX,ADMSKX>
  Structured Extended Features=0x219c91a9<FSGSBASE,BMI1,AVX2,SMEP,BMI2,PQM,PQE,RDSEED,ADX,SMAP,CLFLUSHOPT,CLWB,SHA>
  Structured Extended Features2=0x400004<UMIP,RDPID>
  XSAVE Features=0xf<XSAVEOPT,XSAVEC,XINUSE,XSAVES>
  AMD Extended Feature Extensions ID EBX=0x18cf757<CLZERO,IRPerf,XSaveErPtr,RDPRU,MCOMMIT,WBNOINVD,IBPB,IBRS,STIBP,PREFER_IBRS,PPIN,SSBD>
  SVM: NP,NRIP,VClean,AFlush,DAssist,NAsids=32768
  TSC: P-state invariant, performance statistics
igb0: link state changed to UP
lo0: link state changed to UP
igb0: link state changed to DOWN
uhid0 numa-domain 2 on uhub1
uhid0: <Yubico YubiKey OTP+FIDO+CCID, class 0/0, rev 2.00/5.27, addr 1> on usbus0
cdce0 numa-domain 3 on uhub2
cdce0: <CDC Network Control Model (NCM)> on usbus1
ue0: <USB Ethernet> on cdce0
ue0: Ethernet address: 52:35:a5:fd:9e:64
ums0 numa-domain 3 on uhub2
ums0: <HID Interface> on usbus1
igb0: link state changed to UP
```
## TCP sysctl
```
net.inet.tcp.rfc1323: 1
net.inet.tcp.mssdflt: 536
net.inet.tcp.keepidle: 7200000
net.inet.tcp.keepintvl: 75000
net.inet.tcp.sendspace: 32768
net.inet.tcp.recvspace: 65536
net.inet.tcp.keepinit: 75000
net.inet.tcp.delacktime: 40
net.inet.tcp.v6mssdflt: 1220
net.inet.tcp.states: 0 19 0 0 2 0 0 0 0 0 0
net.inet.tcp.bbr.clrlost: 0
net.inet.tcp.bbr.software_pacing: 0
net.inet.tcp.bbr.hdwr_pacing: 0
net.inet.tcp.bbr.enob_no_hdwr_pacing: 0
net.inet.tcp.bbr.enob_hdwr_pacing: 0
net.inet.tcp.bbr.rtt_tlp_thresh: 1
net.inet.tcp.bbr.reorder_fade: 60000000
net.inet.tcp.bbr.reorder_thresh: 2
net.inet.tcp.bbr.bb_verbose: 0
net.inet.tcp.bbr.sblklimit: 128
net.inet.tcp.bbr.resend_use_tso: 0
net.inet.tcp.bbr.data_after_close: 1
net.inet.tcp.bbr.kill_paceout: 10
net.inet.tcp.bbr.error_paceout: 10000
net.inet.tcp.bbr.cheat_rxt: 1
net.inet.tcp.bbr.policer.false_postive_thresh: 100
net.inet.tcp.bbr.policer.loss_thresh: 196
net.inet.tcp.bbr.policer.false_postive: 0
net.inet.tcp.bbr.policer.from_rack_rxt: 0
net.inet.tcp.bbr.policer.bwratio: 8
net.inet.tcp.bbr.policer.bwdiff: 500
net.inet.tcp.bbr.policer.min_pes: 4
net.inet.tcp.bbr.policer.detect_enable: 1
net.inet.tcp.bbr.minrto: 30
net.inet.tcp.bbr.timeout.rxtmark_sackpassed: 0
net.inet.tcp.bbr.timeout.incr_tmrs: 1
net.inet.tcp.bbr.timeout.pktdelay: 1000
net.inet.tcp.bbr.timeout.minto: 1000
net.inet.tcp.bbr.timeout.tlp_retry: 2
net.inet.tcp.bbr.timeout.maxrto: 4
net.inet.tcp.bbr.timeout.tlp_dack_time: 200000
net.inet.tcp.bbr.timeout.tlp_minto: 10000
net.inet.tcp.bbr.timeout.persmax: 1000000
net.inet.tcp.bbr.timeout.persmin: 250000
net.inet.tcp.bbr.timeout.tlp_uses: 3
net.inet.tcp.bbr.timeout.delack: 100000
net.inet.tcp.bbr.cwnd.drop_limit: 0
net.inet.tcp.bbr.cwnd.target_is_unit: 0
net.inet.tcp.bbr.cwnd.red_mul: 1
net.inet.tcp.bbr.cwnd.red_div: 2
net.inet.tcp.bbr.cwnd.red_growslow: 1
net.inet.tcp.bbr.cwnd.red_scale: 20000
net.inet.tcp.bbr.cwnd.do_loss_red: 600
net.inet.tcp.bbr.cwnd.initwin: 10
net.inet.tcp.bbr.cwnd.lowspeed_min: 4
net.inet.tcp.bbr.cwnd.highspeed_min: 12
net.inet.tcp.bbr.cwnd.max_target_limit: 8
net.inet.tcp.bbr.cwnd.may_shrink: 0
net.inet.tcp.bbr.cwnd.tar_rtt: 0
net.inet.tcp.bbr.startup.loss_exit: 1
net.inet.tcp.bbr.startup.low_gain: 25
net.inet.tcp.bbr.startup.gain: 25
net.inet.tcp.bbr.startup.use_lowerpg: 1
net.inet.tcp.bbr.startup.loss_threshold: 2000
net.inet.tcp.bbr.startup.cheat_iwnd: 1
net.inet.tcp.bbr.states.google_exit_loss: 1
net.inet.tcp.bbr.states.google_gets_earlyout: 1
net.inet.tcp.bbr.states.use_cwnd_maindrain: 1
net.inet.tcp.bbr.states.use_cwnd_subdrain: 1
net.inet.tcp.bbr.states.subdrain_applimited: 1
net.inet.tcp.bbr.states.dr_filter_life: 8
net.inet.tcp.bbr.states.rand_ot_disc: 50
net.inet.tcp.bbr.states.ld_mul: 4
net.inet.tcp.bbr.states.ld_div: 5
net.inet.tcp.bbr.states.gain_extra_time: 1
net.inet.tcp.bbr.states.gain_2_target: 1
net.inet.tcp.bbr.states.drain_2_target: 1
net.inet.tcp.bbr.states.drain_floor: 88
net.inet.tcp.bbr.states.startup_rtt_gain: 0
net.inet.tcp.bbr.states.use_pkt_epoch: 0
net.inet.tcp.bbr.states.idle_restart_threshold: 100000
net.inet.tcp.bbr.states.idle_restart: 0
net.inet.tcp.bbr.measure.noretran: 0
net.inet.tcp.bbr.measure.quanta: 3
net.inet.tcp.bbr.measure.min_measure_before_pace: 4
net.inet.tcp.bbr.measure.min_measure_good_bw: 1
net.inet.tcp.bbr.measure.ts_delta_percent: 150
net.inet.tcp.bbr.measure.ts_peer_delta: 20
net.inet.tcp.bbr.measure.ts_delta: 20000
net.inet.tcp.bbr.measure.ts_can_raise: 0
net.inet.tcp.bbr.measure.ts_limiting: 1
net.inet.tcp.bbr.measure.use_google: 1
net.inet.tcp.bbr.measure.no_sack_needed: 0
net.inet.tcp.bbr.measure.min_i_bw: 62500
net.inet.tcp.bbr.pacing.srtt_div: 2
net.inet.tcp.bbr.pacing.srtt_mul: 1
net.inet.tcp.bbr.pacing.seg_divisor: 1000
net.inet.tcp.bbr.pacing.utter_max: 0
net.inet.tcp.bbr.pacing.seg_floor: 1
net.inet.tcp.bbr.pacing.seg_tso_max: 2
net.inet.tcp.bbr.pacing.tso_min: 1460
net.inet.tcp.bbr.pacing.all_get_min: 0
net.inet.tcp.bbr.pacing.google_discount: 10
net.inet.tcp.bbr.pacing.tcp_oh: 1
net.inet.tcp.bbr.pacing.ip_oh: 1
net.inet.tcp.bbr.pacing.enet_oh: 0
net.inet.tcp.bbr.pacing.seg_deltarg: 7000
net.inet.tcp.bbr.pacing.bw_cross: 2896000
net.inet.tcp.bbr.pacing.hw_pacing_delay_cnt: 10
net.inet.tcp.bbr.pacing.hw_pacing_floor: 1
net.inet.tcp.bbr.pacing.hw_pacing_adj: 2
net.inet.tcp.bbr.pacing.hw_pacing_limit: 8000
net.inet.tcp.bbr.pacing.hw_pacing: 0
net.inet.tcp.bbr.probertt.can_use_ts: 1
net.inet.tcp.bbr.probertt.use_cwnd: 1
net.inet.tcp.bbr.probertt.is_ratio: 0
net.inet.tcp.bbr.probertt.can_adjust: 1
net.inet.tcp.bbr.probertt.enter_sets_force: 0
net.inet.tcp.bbr.probertt.can_force: 0
net.inet.tcp.bbr.probertt.drain_rtt: 3
net.inet.tcp.bbr.probertt.filter_len_sec: 6
net.inet.tcp.bbr.probertt.mintime: 200000
net.inet.tcp.bbr.probertt.int: 4000000
net.inet.tcp.bbr.probertt.cwnd: 4
net.inet.tcp.bbr.probertt.gain: 192
net.inet.tcp.rack.clear: 0
net.inet.tcp.rack.misc.clamp_ca_upper: 105
net.inet.tcp.rack.misc.clamp_ss_upper: 110
net.inet.tcp.rack.misc.rxt_threshs_for_unclamp: 5
net.inet.tcp.rack.misc.rnds_for_unclamp: 100
net.inet.tcp.rack.misc.rnds_for_rxt_clamp: 10
net.inet.tcp.rack.misc.autoscale: 20
net.inet.tcp.rack.misc.prr_sendalot: 1
net.inet.tcp.rack.misc.no_sack_needed: 1
net.inet.tcp.rack.misc.data_after_close: 1
net.inet.tcp.rack.misc.bb_verbose: 0
net.inet.tcp.rack.misc.no_prr: 0
net.inet.tcp.rack.misc.limits_on_scwnd: 1
net.inet.tcp.rack.misc.shared_cwnd: 1
net.inet.tcp.rack.misc.defprofile: 0
net.inet.tcp.rack.misc.clientlowbuf: 0
net.inet.tcp.rack.misc.stats_gets_ms: 1
net.inet.tcp.rack.misc.prr_addback_max: 2
net.inet.tcp.rack.misc.rack_dsack_ctl: 3
net.inet.tcp.rack.misc.apply_rtt_with_low_conf: 0
net.inet.tcp.rack.misc.rack_hibeta: 0
net.inet.tcp.rack.misc.rxt_controls: 0
net.inet.tcp.rack.misc.sad_seg_per: 800
net.inet.tcp.rack.misc.dnd: 0
net.inet.tcp.rack.features.hystartplusplus: 0
net.inet.tcp.rack.features.non_paced_lro_queue: 0
net.inet.tcp.rack.features.rsmrfo: 1
net.inet.tcp.rack.features.rfo: 1
net.inet.tcp.rack.features.fsb: 1
net.inet.tcp.rack.features.cmpack: 1
net.inet.tcp.rack.features.hybrid_set_maxseg: 0
net.inet.tcp.rack.features.rxt_clamp_thresh: 0
net.inet.tcp.rack.measure.min_measure_tim: 0
net.inet.tcp.rack.measure.min_srtts: 1
net.inet.tcp.rack.measure.goal_bdp: 2
net.inet.tcp.rack.measure.min_target: 20
net.inet.tcp.rack.measure.end_rwnd: 0
net.inet.tcp.rack.measure.end_cwnd: 0
net.inet.tcp.rack.measure.wma_divisor: 8
net.inet.tcp.rack.timers.minto: 1000
net.inet.tcp.rack.timers.maxrto: 4000000
net.inet.tcp.rack.timers.minrto: 30000
net.inet.tcp.rack.timers.delayed_ack: 40000
net.inet.tcp.rack.timers.persmax: 2000000
net.inet.tcp.rack.timers.persmin: 250000
net.inet.tcp.rack.tlp.pktdelay: 1000
net.inet.tcp.rack.tlp.reorder_fade: 60000000
net.inet.tcp.rack.tlp.rtt_tlp_thresh: 1
net.inet.tcp.rack.tlp.reorder_thresh: 2
net.inet.tcp.rack.tlp.tlp_cwnd_flag: 0
net.inet.tcp.rack.tlp.rack_tlimit: 0
net.inet.tcp.rack.tlp.send_oldest: 0
net.inet.tcp.rack.tlp.tlpminto: 10000
net.inet.tcp.rack.tlp.use_greater: 1
net.inet.tcp.rack.tlp.limit: 2
net.inet.tcp.rack.tlp.tlpmethod: 2
net.inet.tcp.rack.tlp.nonrxt_use_cr: 0
net.inet.tcp.rack.tlp.post_rec_labc: 2
net.inet.tcp.rack.tlp.use_rrr: 1
net.inet.tcp.rack.timely.bottom_drag_segs: 1
net.inet.tcp.rack.timely.dec_raise_thresh: 100
net.inet.tcp.rack.timely.nonstop: 0
net.inet.tcp.rack.timely.interim_timely_only: 0
net.inet.tcp.rack.timely.noback_max: 0
net.inet.tcp.rack.timely.min_segs: 4
net.inet.tcp.rack.timely.max_push_drop: 3
net.inet.tcp.rack.timely.max_push_rise: 3
net.inet.tcp.rack.timely.red_clear_cnt: 6
net.inet.tcp.rack.timely.no_rec_red: 1
net.inet.tcp.rack.timely.dynamicgp: 0
net.inet.tcp.rack.timely.upperboundca: 0
net.inet.tcp.rack.timely.upperboundss: 0
net.inet.tcp.rack.timely.p5_upper: 250
net.inet.tcp.rack.timely.lowerbound: 50
net.inet.tcp.rack.timely.increase: 2
net.inet.tcp.rack.timely.decrease: 80
net.inet.tcp.rack.timely.rtt_min_mul: 1
net.inet.tcp.rack.timely.rtt_min_div: 4
net.inet.tcp.rack.timely.rtt_max_mul: 3
net.inet.tcp.rack.timely.lower: 4
net.inet.tcp.rack.timely.upper: 2
net.inet.tcp.rack.hdwr_pacing.extra_mss_precise: 0
net.inet.tcp.rack.hdwr_pacing.up_only: 0
net.inet.tcp.rack.hdwr_pacing.rate_to_low: 0
net.inet.tcp.rack.hdwr_pacing.rate_min: 0
net.inet.tcp.rack.hdwr_pacing.uncap_per: 0
net.inet.tcp.rack.hdwr_pacing.rate_cap: 0
net.inet.tcp.rack.hdwr_pacing.enable: 0
net.inet.tcp.rack.hdwr_pacing.pace_enobuf_min: 10000
net.inet.tcp.rack.hdwr_pacing.pace_enobuf_max: 12000
net.inet.tcp.rack.hdwr_pacing.pace_enobuf_mult: 0
net.inet.tcp.rack.hdwr_pacing.precheck: 0
net.inet.tcp.rack.hdwr_pacing.rwnd_factor: 2
net.inet.tcp.rack.req_measure_cnt: 1
net.inet.tcp.rack.use_pacing: 0
net.inet.tcp.rack.pacing.rate_cap: 0
net.inet.tcp.rack.pacing.burst_reduces: 4
net.inet.tcp.rack.pacing.pace_max_seg: 40
net.inet.tcp.rack.pacing.gp_per_rec: 200
net.inet.tcp.rack.pacing.gp_per_ca: 200
net.inet.tcp.rack.pacing.gp_per_ss: 250
net.inet.tcp.rack.pacing.init_win: 0
net.inet.tcp.rack.pacing.limit_wsrtt: 0
net.inet.tcp.rack.pacing.allow1mss: 0
net.inet.tcp.rack.pacing.max_pace_over: 30
net.inet.tcp.rack.pacing.fillcw_max_mult: 2
net.inet.tcp.rack.pacing.divisor: 250
net.inet.tcp.rack.pacing.min_burst: 0
net.inet.tcp.rack.pacing.fillcw: 0
net.inet.tcp.rack.pacing.fullbufdisc: 10
net.inet.tcp.rack.pacing.fulldgpinrec: 1
net.inet.tcp.rack.probertt.hbp_threshold: 3
net.inet.tcp.rack.probertt.hbp_extra_drain: 1
net.inet.tcp.rack.probertt.clear_is_cnts: 1
net.inet.tcp.rack.probertt.must_move: 250000
net.inet.tcp.rack.probertt.lower_within: 10
net.inet.tcp.rack.probertt.filter_life: 10000000
net.inet.tcp.rack.probertt.holdtim_at_target: 40000
net.inet.tcp.rack.probertt.length_mul: 0
net.inet.tcp.rack.probertt.length_div: 0
net.inet.tcp.rack.probertt.goal_use_min_exit: 0
net.inet.tcp.rack.probertt.goal_use_min_entry: 1
net.inet.tcp.rack.probertt.mustdrainsrtts: 1
net.inet.tcp.rack.probertt.maxdrainsrtts: 2
net.inet.tcp.rack.probertt.sets_cwnd: 0
net.inet.tcp.rack.probertt.safety: 2000000
net.inet.tcp.rack.probertt.time_between: 9600000
net.inet.tcp.rack.probertt.gp_per_low: 40
net.inet.tcp.rack.probertt.gp_per_reduce: 10
net.inet.tcp.rack.probertt.gp_per_mul: 60
net.inet.tcp.rack.probertt.exit_per_nonhpb: 130
net.inet.tcp.rack.probertt.exit_per_hpb: 130
net.inet.tcp.rack.rate_sample_method: 1
net.inet.tcp.rack.stats.tried_scwnd: 0
net.inet.tcp.rack.stats.collapsed_win_bytes: 0
net.inet.tcp.rack.stats.collapsed_win_rxt: 0
net.inet.tcp.rack.stats.collapsed_win: 0
net.inet.tcp.rack.stats.collapsed_win_seen: 0
net.inet.tcp.rack.stats.idle_reduce_oninput: 0
net.inet.tcp.rack.stats.sack_short: 0
net.inet.tcp.rack.stats.sack_restart: 0
net.inet.tcp.rack.stats.sack_long: 0
net.inet.tcp.rack.stats.cmp_ack_not: 111290101
net.inet.tcp.rack.stats.cmp_ack_equiv: 0
net.inet.tcp.rack.stats.persist_loss_ends: 0
net.inet.tcp.rack.stats.persist_loss: 0
net.inet.tcp.rack.stats.persist_acks: 0
net.inet.tcp.rack.stats.persist_sends: 0
net.inet.tcp.rack.stats.rxt_clamps_cwnd_uniq: 0
net.inet.tcp.rack.stats.rxt_clamps_cwnd: 0
net.inet.tcp.rack.stats.split_limited: 0
net.inet.tcp.rack.stats.alloc_limited_conns: 0
net.inet.tcp.rack.stats.alloc_limited: 0
net.inet.tcp.rack.stats.allocemerg: 0
net.inet.tcp.rack.stats.allochard: 0
net.inet.tcp.rack.stats.allocs: 51601907
net.inet.tcp.rack.stats.alloc_hot: 22435767
net.inet.tcp.rack.stats.saw_enetunreach: 0
net.inet.tcp.rack.stats.saw_enobufs_hw: 0
net.inet.tcp.rack.stats.saw_enobufs: 0
net.inet.tcp.rack.stats.rack_to_tot: 0
net.inet.tcp.rack.stats.tlp_retran_bytes: 146885
net.inet.tcp.rack.stats.tlp_retran: 16
net.inet.tcp.rack.stats.tlp_new: 0
net.inet.tcp.rack.stats.tlp_to_total: 16
net.inet.tcp.rack.stats.hwpace_lost: 0
net.inet.tcp.rack.stats.hwpace_init_fail: 0
net.inet.tcp.rack.stats.rfo_extended: 2
net.inet.tcp.rack.stats.nfto_send: 110822544
net.inet.tcp.rack.stats.nfto_resend: 1
net.inet.tcp.rack.stats.fto_rsm_send: 15
net.inet.tcp.rack.stats.fto_send: 11689
net.inet.tcp.rack.stats.totalbytes: 1207839264156
net.inet.tcp.rack.sack_attack.ofsplit: 0
net.inet.tcp.rack.sack_attack.skipacked: 0
net.inet.tcp.rack.sack_attack.prevmerge: 0
net.inet.tcp.rack.sack_attack.nextmerge: 0
net.inet.tcp.rack.sack_attack.suspect: 0
net.inet.tcp.rack.sack_attack.reversed: 0
net.inet.tcp.rack.sack_attack.attacks: 0
net.inet.tcp.rack.sack_attack.move_some: 0
net.inet.tcp.rack.sack_attack.move_none: 0
net.inet.tcp.rack.sack_attack.sacktotal: 0
net.inet.tcp.rack.sack_attack.exp_sacktotal: 0
net.inet.tcp.rack.sack_attack.acktotal: 73904976
net.inet.tcp.rack.sack_attack.detect_highmoveratio: 0
net.inet.tcp.rack.sack_attack.detect_highsackratio: 0
net.inet.tcp.rack.sack_attack.merge_out: 0
net.inet.tcp.hpts.63.syscall_cnt: 658613
net.inet.tcp.hpts.63.now_sleeping: 512000
net.inet.tcp.hpts.63.cur_min_sleep: 250
net.inet.tcp.hpts.63.lastran: 3496144897
net.inet.tcp.hpts.63.curtick: 779111219
net.inet.tcp.hpts.63.runtick: 16642
net.inet.tcp.hpts.63.curslot: 52019
net.inet.tcp.hpts.63.active: 0
net.inet.tcp.hpts.63.out_qcnt: 0
net.inet.tcp.hpts.62.syscall_cnt: 684893
net.inet.tcp.hpts.62.now_sleeping: 512000
net.inet.tcp.hpts.62.cur_min_sleep: 250
net.inet.tcp.hpts.62.lastran: 3496145121
net.inet.tcp.hpts.62.curtick: 779111241
net.inet.tcp.hpts.62.runtick: 40080
net.inet.tcp.hpts.62.curslot: 52041
net.inet.tcp.hpts.62.active: 0
net.inet.tcp.hpts.62.out_qcnt: 0
net.inet.tcp.hpts.61.syscall_cnt: 678869
net.inet.tcp.hpts.61.now_sleeping: 512000
net.inet.tcp.hpts.61.cur_min_sleep: 250
net.inet.tcp.hpts.61.lastran: 3496145120
net.inet.tcp.hpts.61.curtick: 779111241
net.inet.tcp.hpts.61.runtick: 8978
net.inet.tcp.hpts.61.curslot: 52041
net.inet.tcp.hpts.61.active: 0
net.inet.tcp.hpts.61.out_qcnt: 0
net.inet.tcp.hpts.60.syscall_cnt: 687168
net.inet.tcp.hpts.60.now_sleeping: 512000
net.inet.tcp.hpts.60.cur_min_sleep: 250
net.inet.tcp.hpts.60.lastran: 3496145119
net.inet.tcp.hpts.60.curtick: 779111241
net.inet.tcp.hpts.60.runtick: 73144
net.inet.tcp.hpts.60.curslot: 52041
net.inet.tcp.hpts.60.active: 0
net.inet.tcp.hpts.60.out_qcnt: 0
net.inet.tcp.hpts.59.syscall_cnt: 672277
net.inet.tcp.hpts.59.now_sleeping: 512000
net.inet.tcp.hpts.59.cur_min_sleep: 250
net.inet.tcp.hpts.59.lastran: 3496145029
net.inet.tcp.hpts.59.curtick: 779111232
net.inet.tcp.hpts.59.runtick: 446
net.inet.tcp.hpts.59.curslot: 52032
net.inet.tcp.hpts.59.active: 0
net.inet.tcp.hpts.59.out_qcnt: 0
net.inet.tcp.hpts.58.syscall_cnt: 694598
net.inet.tcp.hpts.58.now_sleeping: 512000
net.inet.tcp.hpts.58.cur_min_sleep: 250
net.inet.tcp.hpts.58.lastran: 3496144902
net.inet.tcp.hpts.58.curtick: 779111219
net.inet.tcp.hpts.58.runtick: 59577
net.inet.tcp.hpts.58.curslot: 52019
net.inet.tcp.hpts.58.active: 0
net.inet.tcp.hpts.58.out_qcnt: 0
net.inet.tcp.hpts.57.syscall_cnt: 684618
net.inet.tcp.hpts.57.now_sleeping: 512000
net.inet.tcp.hpts.57.cur_min_sleep: 250
net.inet.tcp.hpts.57.lastran: 3496144899
net.inet.tcp.hpts.57.curtick: 779111219
net.inet.tcp.hpts.57.runtick: 477
net.inet.tcp.hpts.57.curslot: 52019
net.inet.tcp.hpts.57.active: 0
net.inet.tcp.hpts.57.out_qcnt: 0
net.inet.tcp.hpts.56.syscall_cnt: 690930
net.inet.tcp.hpts.56.now_sleeping: 512000
net.inet.tcp.hpts.56.cur_min_sleep: 250
net.inet.tcp.hpts.56.lastran: 3496144898
net.inet.tcp.hpts.56.curtick: 779111219
net.inet.tcp.hpts.56.runtick: 83597
net.inet.tcp.hpts.56.curslot: 52019
net.inet.tcp.hpts.56.active: 0
net.inet.tcp.hpts.56.out_qcnt: 0
net.inet.tcp.hpts.55.syscall_cnt: 625271
net.inet.tcp.hpts.55.now_sleeping: 512000
net.inet.tcp.hpts.55.cur_min_sleep: 250
net.inet.tcp.hpts.55.lastran: 3496133918
net.inet.tcp.hpts.55.curtick: 779110121
net.inet.tcp.hpts.55.runtick: 67709
net.inet.tcp.hpts.55.curslot: 50921
net.inet.tcp.hpts.55.active: 0
net.inet.tcp.hpts.55.out_qcnt: 0
net.inet.tcp.hpts.54.syscall_cnt: 660576
net.inet.tcp.hpts.54.now_sleeping: 512000
net.inet.tcp.hpts.54.cur_min_sleep: 250
net.inet.tcp.hpts.54.lastran: 3496133908
net.inet.tcp.hpts.54.curtick: 779110120
net.inet.tcp.hpts.54.runtick: 12188
net.inet.tcp.hpts.54.curslot: 50920
net.inet.tcp.hpts.54.active: 0
net.inet.tcp.hpts.54.out_qcnt: 0
net.inet.tcp.hpts.53.syscall_cnt: 656909
net.inet.tcp.hpts.53.now_sleeping: 512000
net.inet.tcp.hpts.53.cur_min_sleep: 250
net.inet.tcp.hpts.53.lastran: 3496133925
net.inet.tcp.hpts.53.curtick: 779110122
net.inet.tcp.hpts.53.runtick: 54883
net.inet.tcp.hpts.53.curslot: 50922
net.inet.tcp.hpts.53.active: 0
net.inet.tcp.hpts.53.out_qcnt: 0
net.inet.tcp.hpts.52.syscall_cnt: 611984
net.inet.tcp.hpts.52.now_sleeping: 512000
net.inet.tcp.hpts.52.cur_min_sleep: 250
net.inet.tcp.hpts.52.lastran: 3496133338
net.inet.tcp.hpts.52.curtick: 779110063
net.inet.tcp.hpts.52.runtick: 61186
net.inet.tcp.hpts.52.curslot: 50863
net.inet.tcp.hpts.52.active: 0
net.inet.tcp.hpts.52.out_qcnt: 0
net.inet.tcp.hpts.51.syscall_cnt: 629497
net.inet.tcp.hpts.51.now_sleeping: 512000
net.inet.tcp.hpts.51.cur_min_sleep: 250
net.inet.tcp.hpts.51.lastran: 3496133913
net.inet.tcp.hpts.51.curtick: 779110120
net.inet.tcp.hpts.51.runtick: 83610
net.inet.tcp.hpts.51.curslot: 50920
net.inet.tcp.hpts.51.active: 0
net.inet.tcp.hpts.51.out_qcnt: 0
net.inet.tcp.hpts.50.syscall_cnt: 667700
net.inet.tcp.hpts.50.now_sleeping: 512000
net.inet.tcp.hpts.50.cur_min_sleep: 250
net.inet.tcp.hpts.50.lastran: 3496133920
net.inet.tcp.hpts.50.curtick: 779110121
net.inet.tcp.hpts.50.runtick: 83604
net.inet.tcp.hpts.50.curslot: 50921
net.inet.tcp.hpts.50.active: 0
net.inet.tcp.hpts.50.out_qcnt: 0
net.inet.tcp.hpts.49.syscall_cnt: 633435
net.inet.tcp.hpts.49.now_sleeping: 512000
net.inet.tcp.hpts.49.cur_min_sleep: 250
net.inet.tcp.hpts.49.lastran: 3496133919
net.inet.tcp.hpts.49.curtick: 779110121
net.inet.tcp.hpts.49.runtick: 24314
net.inet.tcp.hpts.49.curslot: 50921
net.inet.tcp.hpts.49.active: 0
net.inet.tcp.hpts.49.out_qcnt: 0
net.inet.tcp.hpts.48.syscall_cnt: 653288
net.inet.tcp.hpts.48.now_sleeping: 512000
net.inet.tcp.hpts.48.cur_min_sleep: 250
net.inet.tcp.hpts.48.lastran: 3496133915
net.inet.tcp.hpts.48.curtick: 779110121
net.inet.tcp.hpts.48.runtick: 15543
net.inet.tcp.hpts.48.curslot: 50921
net.inet.tcp.hpts.48.active: 0
net.inet.tcp.hpts.48.out_qcnt: 0
net.inet.tcp.hpts.47.syscall_cnt: 1220966
net.inet.tcp.hpts.47.now_sleeping: 512000
net.inet.tcp.hpts.47.cur_min_sleep: 250
net.inet.tcp.hpts.47.lastran: 3496150320
net.inet.tcp.hpts.47.curtick: 779111762
net.inet.tcp.hpts.47.runtick: 80816
net.inet.tcp.hpts.47.curslot: 52564
net.inet.tcp.hpts.47.active: 0
net.inet.tcp.hpts.47.out_qcnt: 0
net.inet.tcp.hpts.46.syscall_cnt: 1212075
net.inet.tcp.hpts.46.now_sleeping: 512000
net.inet.tcp.hpts.46.cur_min_sleep: 250
net.inet.tcp.hpts.46.lastran: 3496150409
net.inet.tcp.hpts.46.curtick: 779111771
net.inet.tcp.hpts.46.runtick: 49759
net.inet.tcp.hpts.46.curslot: 52573
net.inet.tcp.hpts.46.active: 0
net.inet.tcp.hpts.46.out_qcnt: 0
net.inet.tcp.hpts.45.syscall_cnt: 1225008
net.inet.tcp.hpts.45.now_sleeping: 512000
net.inet.tcp.hpts.45.cur_min_sleep: 250
net.inet.tcp.hpts.45.lastran: 3496150505
net.inet.tcp.hpts.45.curtick: 779111781
net.inet.tcp.hpts.45.runtick: 72971
net.inet.tcp.hpts.45.curslot: 52582
net.inet.tcp.hpts.45.active: 0
net.inet.tcp.hpts.45.out_qcnt: 0
net.inet.tcp.hpts.44.syscall_cnt: 1219832
net.inet.tcp.hpts.44.now_sleeping: 512000
net.inet.tcp.hpts.44.cur_min_sleep: 250
net.inet.tcp.hpts.44.lastran: 3496150596
net.inet.tcp.hpts.44.curtick: 779111790
net.inet.tcp.hpts.44.runtick: 75603
net.inet.tcp.hpts.44.curslot: 52592
net.inet.tcp.hpts.44.active: 0
net.inet.tcp.hpts.44.out_qcnt: 0
net.inet.tcp.hpts.43.syscall_cnt: 1282508
net.inet.tcp.hpts.43.now_sleeping: 512000
net.inet.tcp.hpts.43.cur_min_sleep: 250
net.inet.tcp.hpts.43.lastran: 3496150677
net.inet.tcp.hpts.43.curtick: 779111798
net.inet.tcp.hpts.43.runtick: 54186
net.inet.tcp.hpts.43.curslot: 52600
net.inet.tcp.hpts.43.active: 0
net.inet.tcp.hpts.43.out_qcnt: 0
net.inet.tcp.hpts.42.syscall_cnt: 1824895
net.inet.tcp.hpts.42.now_sleeping: 512000
net.inet.tcp.hpts.42.cur_min_sleep: 250
net.inet.tcp.hpts.42.lastran: 3496150773
net.inet.tcp.hpts.42.curtick: 779111807
net.inet.tcp.hpts.42.runtick: 51763
net.inet.tcp.hpts.42.curslot: 52609
net.inet.tcp.hpts.42.active: 0
net.inet.tcp.hpts.42.out_qcnt: 0
net.inet.tcp.hpts.41.syscall_cnt: 1931456
net.inet.tcp.hpts.41.now_sleeping: 512000
net.inet.tcp.hpts.41.cur_min_sleep: 250
net.inet.tcp.hpts.41.lastran: 3496150860
net.inet.tcp.hpts.41.curtick: 779111816
net.inet.tcp.hpts.41.runtick: 39686
net.inet.tcp.hpts.41.curslot: 52618
net.inet.tcp.hpts.41.active: 0
net.inet.tcp.hpts.41.out_qcnt: 0
net.inet.tcp.hpts.40.syscall_cnt: 1914654
net.inet.tcp.hpts.40.now_sleeping: 512000
net.inet.tcp.hpts.40.cur_min_sleep: 250
net.inet.tcp.hpts.40.lastran: 3496150955
net.inet.tcp.hpts.40.curtick: 779111826
net.inet.tcp.hpts.40.runtick: 71996
net.inet.tcp.hpts.40.curslot: 52627
net.inet.tcp.hpts.40.active: 0
net.inet.tcp.hpts.40.out_qcnt: 0
net.inet.tcp.hpts.39.syscall_cnt: 473330
net.inet.tcp.hpts.39.now_sleeping: 512000
net.inet.tcp.hpts.39.cur_min_sleep: 250
net.inet.tcp.hpts.39.lastran: 3496142638
net.inet.tcp.hpts.39.curtick: 779110993
net.inet.tcp.hpts.39.runtick: 12292
net.inet.tcp.hpts.39.curslot: 51793
net.inet.tcp.hpts.39.active: 0
net.inet.tcp.hpts.39.out_qcnt: 0
net.inet.tcp.hpts.38.syscall_cnt: 469487
net.inet.tcp.hpts.38.now_sleeping: 512000
net.inet.tcp.hpts.38.cur_min_sleep: 250
net.inet.tcp.hpts.38.lastran: 3496144207
net.inet.tcp.hpts.38.curtick: 779111150
net.inet.tcp.hpts.38.runtick: 3073
net.inet.tcp.hpts.38.curslot: 51950
net.inet.tcp.hpts.38.active: 0
net.inet.tcp.hpts.38.out_qcnt: 0
net.inet.tcp.hpts.37.syscall_cnt: 486369
net.inet.tcp.hpts.37.now_sleeping: 512000
net.inet.tcp.hpts.37.cur_min_sleep: 250
net.inet.tcp.hpts.37.lastran: 3496142663
net.inet.tcp.hpts.37.curtick: 779110995
net.inet.tcp.hpts.37.runtick: 15548
net.inet.tcp.hpts.37.curslot: 51795
net.inet.tcp.hpts.37.active: 0
net.inet.tcp.hpts.37.out_qcnt: 0
net.inet.tcp.hpts.36.syscall_cnt: 475122
net.inet.tcp.hpts.36.now_sleeping: 512000
net.inet.tcp.hpts.36.cur_min_sleep: 250
net.inet.tcp.hpts.36.lastran: 3496142653
net.inet.tcp.hpts.36.curtick: 779110994
net.inet.tcp.hpts.36.runtick: 26007
net.inet.tcp.hpts.36.curslot: 51794
net.inet.tcp.hpts.36.active: 0
net.inet.tcp.hpts.36.out_qcnt: 0
net.inet.tcp.hpts.35.syscall_cnt: 499656
net.inet.tcp.hpts.35.now_sleeping: 512000
net.inet.tcp.hpts.35.cur_min_sleep: 250
net.inet.tcp.hpts.35.lastran: 3496142637
net.inet.tcp.hpts.35.curtick: 779110993
net.inet.tcp.hpts.35.runtick: 72927
net.inet.tcp.hpts.35.curslot: 51793
net.inet.tcp.hpts.35.active: 0
net.inet.tcp.hpts.35.out_qcnt: 0
net.inet.tcp.hpts.34.syscall_cnt: 477008
net.inet.tcp.hpts.34.now_sleeping: 512000
net.inet.tcp.hpts.34.cur_min_sleep: 250
net.inet.tcp.hpts.34.lastran: 3496142650
net.inet.tcp.hpts.34.curtick: 779110994
net.inet.tcp.hpts.34.runtick: 96663
net.inet.tcp.hpts.34.curslot: 51794
net.inet.tcp.hpts.34.active: 0
net.inet.tcp.hpts.34.out_qcnt: 0
net.inet.tcp.hpts.33.syscall_cnt: 471183
net.inet.tcp.hpts.33.now_sleeping: 512000
net.inet.tcp.hpts.33.cur_min_sleep: 250
net.inet.tcp.hpts.33.lastran: 3496142639
net.inet.tcp.hpts.33.curtick: 779110993
net.inet.tcp.hpts.33.runtick: 56227
net.inet.tcp.hpts.33.curslot: 51793
net.inet.tcp.hpts.33.active: 0
net.inet.tcp.hpts.33.out_qcnt: 0
net.inet.tcp.hpts.32.syscall_cnt: 494960
net.inet.tcp.hpts.32.now_sleeping: 512000
net.inet.tcp.hpts.32.cur_min_sleep: 250
net.inet.tcp.hpts.32.lastran: 3496142637
net.inet.tcp.hpts.32.curtick: 779110993
net.inet.tcp.hpts.32.runtick: 21329
net.inet.tcp.hpts.32.curslot: 51793
net.inet.tcp.hpts.32.active: 0
net.inet.tcp.hpts.32.out_qcnt: 0
net.inet.tcp.hpts.31.syscall_cnt: 719212
net.inet.tcp.hpts.31.now_sleeping: 512000
net.inet.tcp.hpts.31.cur_min_sleep: 250
net.inet.tcp.hpts.31.lastran: 3496144349
net.inet.tcp.hpts.31.curtick: 779111164
net.inet.tcp.hpts.31.runtick: 77377
net.inet.tcp.hpts.31.curslot: 51964
net.inet.tcp.hpts.31.active: 0
net.inet.tcp.hpts.31.out_qcnt: 0
net.inet.tcp.hpts.30.syscall_cnt: 737613
net.inet.tcp.hpts.30.now_sleeping: 512000
net.inet.tcp.hpts.30.cur_min_sleep: 250
net.inet.tcp.hpts.30.lastran: 3496144292
net.inet.tcp.hpts.30.curtick: 779111158
net.inet.tcp.hpts.30.runtick: 52020
net.inet.tcp.hpts.30.curslot: 51958
net.inet.tcp.hpts.30.active: 0
net.inet.tcp.hpts.30.out_qcnt: 0
net.inet.tcp.hpts.29.syscall_cnt: 727523
net.inet.tcp.hpts.29.now_sleeping: 512000
net.inet.tcp.hpts.29.cur_min_sleep: 250
net.inet.tcp.hpts.29.lastran: 3496144318
net.inet.tcp.hpts.29.curtick: 779111161
net.inet.tcp.hpts.29.runtick: 35615
net.inet.tcp.hpts.29.curslot: 51961
net.inet.tcp.hpts.29.active: 0
net.inet.tcp.hpts.29.out_qcnt: 0
net.inet.tcp.hpts.28.syscall_cnt: 737967
net.inet.tcp.hpts.28.now_sleeping: 512000
net.inet.tcp.hpts.28.cur_min_sleep: 250
net.inet.tcp.hpts.28.lastran: 3496144309
net.inet.tcp.hpts.28.curtick: 779111160
net.inet.tcp.hpts.28.runtick: 18461
net.inet.tcp.hpts.28.curslot: 51960
net.inet.tcp.hpts.28.active: 0
net.inet.tcp.hpts.28.out_qcnt: 0
net.inet.tcp.hpts.27.syscall_cnt: 727037
net.inet.tcp.hpts.27.now_sleeping: 512000
net.inet.tcp.hpts.27.cur_min_sleep: 250
net.inet.tcp.hpts.27.lastran: 3496144287
net.inet.tcp.hpts.27.curtick: 779111158
net.inet.tcp.hpts.27.runtick: 45815
net.inet.tcp.hpts.27.curslot: 51958
net.inet.tcp.hpts.27.active: 0
net.inet.tcp.hpts.27.out_qcnt: 0
net.inet.tcp.hpts.26.syscall_cnt: 742754
net.inet.tcp.hpts.26.now_sleeping: 512000
net.inet.tcp.hpts.26.cur_min_sleep: 250
net.inet.tcp.hpts.26.lastran: 3496144308
net.inet.tcp.hpts.26.curtick: 779111160
net.inet.tcp.hpts.26.runtick: 8931
net.inet.tcp.hpts.26.curslot: 51960
net.inet.tcp.hpts.26.active: 0
net.inet.tcp.hpts.26.out_qcnt: 0
net.inet.tcp.hpts.25.syscall_cnt: 753287
net.inet.tcp.hpts.25.now_sleeping: 512000
net.inet.tcp.hpts.25.cur_min_sleep: 250
net.inet.tcp.hpts.25.lastran: 3496144352
net.inet.tcp.hpts.25.curtick: 779111164
net.inet.tcp.hpts.25.runtick: 25444
net.inet.tcp.hpts.25.curslot: 51964
net.inet.tcp.hpts.25.active: 0
net.inet.tcp.hpts.25.out_qcnt: 0
net.inet.tcp.hpts.24.syscall_cnt: 779174
net.inet.tcp.hpts.24.now_sleeping: 512000
net.inet.tcp.hpts.24.cur_min_sleep: 250
net.inet.tcp.hpts.24.lastran: 3496144319
net.inet.tcp.hpts.24.curtick: 779111161
net.inet.tcp.hpts.24.runtick: 46645
net.inet.tcp.hpts.24.curslot: 51961
net.inet.tcp.hpts.24.active: 0
net.inet.tcp.hpts.24.out_qcnt: 0
net.inet.tcp.hpts.23.syscall_cnt: 2311767
net.inet.tcp.hpts.23.now_sleeping: 512000
net.inet.tcp.hpts.23.cur_min_sleep: 250
net.inet.tcp.hpts.23.lastran: 3496143941
net.inet.tcp.hpts.23.curtick: 779111123
net.inet.tcp.hpts.23.runtick: 54509
net.inet.tcp.hpts.23.curslot: 51923
net.inet.tcp.hpts.23.active: 0
net.inet.tcp.hpts.23.out_qcnt: 0
net.inet.tcp.hpts.22.syscall_cnt: 2343313
net.inet.tcp.hpts.22.now_sleeping: 512000
net.inet.tcp.hpts.22.cur_min_sleep: 250
net.inet.tcp.hpts.22.lastran: 3496143946
net.inet.tcp.hpts.22.curtick: 779111124
net.inet.tcp.hpts.22.runtick: 101753
net.inet.tcp.hpts.22.curslot: 51924
net.inet.tcp.hpts.22.active: 0
net.inet.tcp.hpts.22.out_qcnt: 0
net.inet.tcp.hpts.21.syscall_cnt: 2331832
net.inet.tcp.hpts.21.now_sleeping: 512000
net.inet.tcp.hpts.21.cur_min_sleep: 250
net.inet.tcp.hpts.21.lastran: 3496143953
net.inet.tcp.hpts.21.curtick: 779111124
net.inet.tcp.hpts.21.runtick: 56247
net.inet.tcp.hpts.21.curslot: 51924
net.inet.tcp.hpts.21.active: 0
net.inet.tcp.hpts.21.out_qcnt: 0
net.inet.tcp.hpts.20.syscall_cnt: 2373917
net.inet.tcp.hpts.20.now_sleeping: 512000
net.inet.tcp.hpts.20.cur_min_sleep: 250
net.inet.tcp.hpts.20.lastran: 3496143961
net.inet.tcp.hpts.20.curtick: 779111125
net.inet.tcp.hpts.20.runtick: 59541
net.inet.tcp.hpts.20.curslot: 51925
net.inet.tcp.hpts.20.active: 0
net.inet.tcp.hpts.20.out_qcnt: 0
net.inet.tcp.hpts.19.syscall_cnt: 2370504
net.inet.tcp.hpts.19.now_sleeping: 512000
net.inet.tcp.hpts.19.cur_min_sleep: 250
net.inet.tcp.hpts.19.lastran: 3496143965
net.inet.tcp.hpts.19.curtick: 779111126
net.inet.tcp.hpts.19.runtick: 24339
net.inet.tcp.hpts.19.curslot: 51926
net.inet.tcp.hpts.19.active: 0
net.inet.tcp.hpts.19.out_qcnt: 0
net.inet.tcp.hpts.18.syscall_cnt: 2407859
net.inet.tcp.hpts.18.now_sleeping: 512000
net.inet.tcp.hpts.18.cur_min_sleep: 250
net.inet.tcp.hpts.18.lastran: 3496143957
net.inet.tcp.hpts.18.curtick: 779111125
net.inet.tcp.hpts.18.runtick: 76714
net.inet.tcp.hpts.18.curslot: 51925
net.inet.tcp.hpts.18.active: 0
net.inet.tcp.hpts.18.out_qcnt: 0
net.inet.tcp.hpts.17.syscall_cnt: 2433991
net.inet.tcp.hpts.17.now_sleeping: 512000
net.inet.tcp.hpts.17.cur_min_sleep: 250
net.inet.tcp.hpts.17.lastran: 3496143940
net.inet.tcp.hpts.17.curtick: 779111123
net.inet.tcp.hpts.17.runtick: 12144
net.inet.tcp.hpts.17.curslot: 51923
net.inet.tcp.hpts.17.active: 0
net.inet.tcp.hpts.17.out_qcnt: 0
net.inet.tcp.hpts.16.syscall_cnt: 2455630
net.inet.tcp.hpts.16.now_sleeping: 512000
net.inet.tcp.hpts.16.cur_min_sleep: 250
net.inet.tcp.hpts.16.lastran: 3496143951
net.inet.tcp.hpts.16.curtick: 779111124
net.inet.tcp.hpts.16.runtick: 83319
net.inet.tcp.hpts.16.curslot: 51924
net.inet.tcp.hpts.16.active: 0
net.inet.tcp.hpts.16.out_qcnt: 0
net.inet.tcp.hpts.15.syscall_cnt: 407511
net.inet.tcp.hpts.15.now_sleeping: 512000
net.inet.tcp.hpts.15.cur_min_sleep: 250
net.inet.tcp.hpts.15.lastran: 3496138682
net.inet.tcp.hpts.15.curtick: 779110597
net.inet.tcp.hpts.15.runtick: 29316
net.inet.tcp.hpts.15.curslot: 51397
net.inet.tcp.hpts.15.active: 0
net.inet.tcp.hpts.15.out_qcnt: 0
net.inet.tcp.hpts.14.syscall_cnt: 437955
net.inet.tcp.hpts.14.now_sleeping: 512000
net.inet.tcp.hpts.14.cur_min_sleep: 250
net.inet.tcp.hpts.14.lastran: 3496138294
net.inet.tcp.hpts.14.curtick: 779110559
net.inet.tcp.hpts.14.runtick: 59578
net.inet.tcp.hpts.14.curslot: 51359
net.inet.tcp.hpts.14.active: 0
net.inet.tcp.hpts.14.out_qcnt: 0
net.inet.tcp.hpts.13.syscall_cnt: 430620
net.inet.tcp.hpts.13.now_sleeping: 512000
net.inet.tcp.hpts.13.cur_min_sleep: 250
net.inet.tcp.hpts.13.lastran: 3496138674
net.inet.tcp.hpts.13.curtick: 779110597
net.inet.tcp.hpts.13.runtick: 25931
net.inet.tcp.hpts.13.curslot: 51397
net.inet.tcp.hpts.13.active: 0
net.inet.tcp.hpts.13.out_qcnt: 0
net.inet.tcp.hpts.12.syscall_cnt: 429198
net.inet.tcp.hpts.12.now_sleeping: 512000
net.inet.tcp.hpts.12.cur_min_sleep: 250
net.inet.tcp.hpts.12.lastran: 3496138293
net.inet.tcp.hpts.12.curtick: 779110558
net.inet.tcp.hpts.12.runtick: 75565
net.inet.tcp.hpts.12.curslot: 51358
net.inet.tcp.hpts.12.active: 0
net.inet.tcp.hpts.12.out_qcnt: 0
net.inet.tcp.hpts.11.syscall_cnt: 435181
net.inet.tcp.hpts.11.now_sleeping: 512000
net.inet.tcp.hpts.11.cur_min_sleep: 250
net.inet.tcp.hpts.11.lastran: 3496138291
net.inet.tcp.hpts.11.curtick: 779110558
net.inet.tcp.hpts.11.runtick: 41937
net.inet.tcp.hpts.11.curslot: 51358
net.inet.tcp.hpts.11.active: 0
net.inet.tcp.hpts.11.out_qcnt: 0
net.inet.tcp.hpts.10.syscall_cnt: 449294
net.inet.tcp.hpts.10.now_sleeping: 512000
net.inet.tcp.hpts.10.cur_min_sleep: 250
net.inet.tcp.hpts.10.lastran: 3496138298
net.inet.tcp.hpts.10.curtick: 779110559
net.inet.tcp.hpts.10.runtick: 97113
net.inet.tcp.hpts.10.curslot: 51359
net.inet.tcp.hpts.10.active: 0
net.inet.tcp.hpts.10.out_qcnt: 0
net.inet.tcp.hpts.9.syscall_cnt: 460545
net.inet.tcp.hpts.9.now_sleeping: 512000
net.inet.tcp.hpts.9.cur_min_sleep: 250
net.inet.tcp.hpts.9.lastran: 3496138289
net.inet.tcp.hpts.9.curtick: 779110558
net.inet.tcp.hpts.9.runtick: 72963
net.inet.tcp.hpts.9.curslot: 51358
net.inet.tcp.hpts.9.active: 0
net.inet.tcp.hpts.9.out_qcnt: 0
net.inet.tcp.hpts.8.syscall_cnt: 434656
net.inet.tcp.hpts.8.now_sleeping: 512000
net.inet.tcp.hpts.8.cur_min_sleep: 250
net.inet.tcp.hpts.8.lastran: 3496138296
net.inet.tcp.hpts.8.curtick: 779110559
net.inet.tcp.hpts.8.runtick: 15633
net.inet.tcp.hpts.8.curslot: 51359
net.inet.tcp.hpts.8.active: 0
net.inet.tcp.hpts.8.out_qcnt: 0
net.inet.tcp.hpts.7.syscall_cnt: 11819335
net.inet.tcp.hpts.7.now_sleeping: 512000
net.inet.tcp.hpts.7.cur_min_sleep: 250
net.inet.tcp.hpts.7.lastran: 3496144267
net.inet.tcp.hpts.7.curtick: 779111156
net.inet.tcp.hpts.7.runtick: 91980
net.inet.tcp.hpts.7.curslot: 51956
net.inet.tcp.hpts.7.active: 0
net.inet.tcp.hpts.7.out_qcnt: 0
net.inet.tcp.hpts.6.syscall_cnt: 11872046
net.inet.tcp.hpts.6.now_sleeping: 512000
net.inet.tcp.hpts.6.cur_min_sleep: 250
net.inet.tcp.hpts.6.lastran: 3496144273
net.inet.tcp.hpts.6.curtick: 779111156
net.inet.tcp.hpts.6.runtick: 4918
net.inet.tcp.hpts.6.curslot: 51956
net.inet.tcp.hpts.6.active: 0
net.inet.tcp.hpts.6.out_qcnt: 0
net.inet.tcp.hpts.5.syscall_cnt: 11923523
net.inet.tcp.hpts.5.now_sleeping: 512000
net.inet.tcp.hpts.5.cur_min_sleep: 250
net.inet.tcp.hpts.5.lastran: 3496144341
net.inet.tcp.hpts.5.curtick: 779111163
net.inet.tcp.hpts.5.runtick: 32619
net.inet.tcp.hpts.5.curslot: 51963
net.inet.tcp.hpts.5.active: 0
net.inet.tcp.hpts.5.out_qcnt: 0
net.inet.tcp.hpts.4.syscall_cnt: 11945550
net.inet.tcp.hpts.4.now_sleeping: 512000
net.inet.tcp.hpts.4.cur_min_sleep: 250
net.inet.tcp.hpts.4.lastran: 3496144340
net.inet.tcp.hpts.4.curtick: 779111163
net.inet.tcp.hpts.4.runtick: 92441
net.inet.tcp.hpts.4.curslot: 51963
net.inet.tcp.hpts.4.active: 0
net.inet.tcp.hpts.4.out_qcnt: 0
net.inet.tcp.hpts.3.syscall_cnt: 12026840
net.inet.tcp.hpts.3.now_sleeping: 512000
net.inet.tcp.hpts.3.cur_min_sleep: 250
net.inet.tcp.hpts.3.lastran: 3496144266
net.inet.tcp.hpts.3.curtick: 779111156
net.inet.tcp.hpts.3.runtick: 77009
net.inet.tcp.hpts.3.curslot: 51956
net.inet.tcp.hpts.3.active: 0
net.inet.tcp.hpts.3.out_qcnt: 0
net.inet.tcp.hpts.2.syscall_cnt: 12067362
net.inet.tcp.hpts.2.now_sleeping: 512000
net.inet.tcp.hpts.2.cur_min_sleep: 250
net.inet.tcp.hpts.2.lastran: 3496144275
net.inet.tcp.hpts.2.curtick: 779111157
net.inet.tcp.hpts.2.runtick: 41882
net.inet.tcp.hpts.2.curslot: 51957
net.inet.tcp.hpts.2.active: 0
net.inet.tcp.hpts.2.out_qcnt: 0
net.inet.tcp.hpts.1.syscall_cnt: 12117883
net.inet.tcp.hpts.1.now_sleeping: 512000
net.inet.tcp.hpts.1.cur_min_sleep: 250
net.inet.tcp.hpts.1.lastran: 3496144273
net.inet.tcp.hpts.1.curtick: 779111156
net.inet.tcp.hpts.1.runtick: 87369
net.inet.tcp.hpts.1.curslot: 51956
net.inet.tcp.hpts.1.active: 0
net.inet.tcp.hpts.1.out_qcnt: 0
net.inet.tcp.hpts.0.syscall_cnt: 12182739
net.inet.tcp.hpts.0.now_sleeping: 512000
net.inet.tcp.hpts.0.cur_min_sleep: 250
net.inet.tcp.hpts.0.lastran: 3496144343
net.inet.tcp.hpts.0.curtick: 779111163
net.inet.tcp.hpts.0.runtick: 88352
net.inet.tcp.hpts.0.curslot: 51963
net.inet.tcp.hpts.0.active: 0
net.inet.tcp.hpts.0.out_qcnt: 0
net.inet.tcp.hpts.nowake_over_thresh: 1
net.inet.tcp.hpts.less_sleep: 1000
net.inet.tcp.hpts.more_sleep: 100
net.inet.tcp.hpts.minsleep: 250
net.inet.tcp.hpts.maxsleep: 51200
net.inet.tcp.hpts.loopmax: 10
net.inet.tcp.hpts.dyn_maxsleep: 5000
net.inet.tcp.hpts.dyn_minsleep: 250
net.inet.tcp.hpts.logging: 0
net.inet.tcp.hpts.cnt_thresh: 100
net.inet.tcp.hpts.precision: 120
net.inet.tcp.hpts.use_irq: 0
net.inet.tcp.hpts.bind_hptss: 2
net.inet.tcp.hpts.stats.cpusel_random: 218
net.inet.tcp.hpts.stats.cpusel_flowid: 0
net.inet.tcp.hpts.stats.back_tosleep: 23
net.inet.tcp.hpts.stats.direct_awakening: 732321
net.inet.tcp.hpts.stats.timeout_wakeup: 13259191
net.inet.tcp.hpts.stats.direct_call: 150666320
net.inet.tcp.hpts.stats.wheel_wrap: 0
net.inet.tcp.hpts.stats.comb_wheel_wrap: 0
net.inet.tcp.hpts.stats.no_tcbsfound: 0
net.inet.tcp.hpts.stats.loops: 1439370
net.inet.tcp.hpts.stats.hopeless: 0
net.inet.tcp.nolocaltimewait: 1
net.inet.tcp.retries: 12
net.inet.tcp.per_cpu_timers: 0
net.inet.tcp.v6pmtud_blackhole_mss: 1220
net.inet.tcp.pmtud_blackhole_mss: 1200
net.inet.tcp.pmtud_blackhole_detection: 0
net.inet.tcp.maxunacktime: 0
net.inet.tcp.rexmit_drop_options: 0
net.inet.tcp.keepcnt: 8
net.inet.tcp.finwait2_timeout: 60000
net.inet.tcp.fast_finwait2_recycle: 0
net.inet.tcp.always_keepalive: 1
net.inet.tcp.rexmit_slop: 200
net.inet.tcp.rexmit_min: 30
net.inet.tcp.rexmit_initial: 1000
net.inet.tcp.msl: 30000
net.inet.tcp.persmax: 60000
net.inet.tcp.persmin: 5000
net.inet.tcp.syncache.rst_on_sock_fail: 1
net.inet.tcp.syncache.rexmtlimit: 3
net.inet.tcp.syncache.see_other: 0
net.inet.tcp.syncache.hashsize: 512
net.inet.tcp.syncache.count: 0
net.inet.tcp.syncache.cachelimit: 15360
net.inet.tcp.syncache.bucketlimit: 30
net.inet.tcp.functions_inherit_listen_socket_stack: 1
net.inet.tcp.syncookies_only: 0
net.inet.tcp.syncookies: 1
net.inet.tcp.udp_tunneling_overhead: 8
net.inet.tcp.udp_tunneling_port: 0
net.inet.tcp.functions_available: 
Stack                           D Alias                            PCB count
freebsd                         * freebsd                          21
rack                              rack                             0
bbr                               bbr                              0

net.inet.tcp.functions_default: freebsd
net.inet.tcp.split_limit: 0
net.inet.tcp.map_limit: 0
net.inet.tcp.soreceive_stream: 0
net.inet.tcp.isn_reseed_interval: 0
net.inet.tcp.icmp_may_rst: 1
net.inet.tcp.pcbcount: 21
net.inet.tcp.do_tcpdrain: 1
net.inet.tcp.tcbhashsize: 2097152
net.inet.tcp.log_debug: 0
net.inet.tcp.pacing_failures: 0
net.inet.tcp.pacing_count: 0
net.inet.tcp.pacing_limit: 10000
net.inet.tcp.ts_offset_per_conn: 1
net.inet.tcp.tolerate_missing_ts: 1
net.inet.tcp.minmss: 216
net.inet.tcp.ack_war_cnt: 5
net.inet.tcp.ack_war_timewindow: 1000
net.inet.tcp.sack.globalholes: 0
net.inet.tcp.sack.globalmaxholes: 65536
net.inet.tcp.sack.maxholes: 128
net.inet.tcp.sack.lrd: 1
net.inet.tcp.sack.revised: 1
net.inet.tcp.sack.enable: 1
net.inet.tcp.reass.queueguard: 16
net.inet.tcp.reass.new_limit: 0
net.inet.tcp.reass.maxqueuelen: 100
net.inet.tcp.reass.cursegments: 0
net.inet.tcp.reass.maxsegments: 1021014
net.inet.tcp.sendbuf_auto_lowat: 0
net.inet.tcp.sendbuf_max: 2097152
net.inet.tcp.sendbuf_inc: 8192
net.inet.tcp.sendbuf_auto: 1
net.inet.tcp.tso: 1
net.inet.tcp.path_mtu_discovery: 1
net.inet.tcp.lro.lro_badcsum: 0
net.inet.tcp.lro.without_m_ackcmp: 0
net.inet.tcp.lro.with_m_ackcmp: 0
net.inet.tcp.lro.would_have_but: 0
net.inet.tcp.lro.extra_mbuf: 0
net.inet.tcp.lro.lockcnt: 0
net.inet.tcp.lro.compressed: 0
net.inet.tcp.lro.wokeup: 0
net.inet.tcp.lro.fullqueue: 0
net.inet.tcp.lro.lro_less_accurate: 0
net.inet.tcp.lro.lro_cpu_threshold: 50
net.inet.tcp.lro.entries: 8
net.inet.tcp.bb.pcb_ids_tot: 0
net.inet.tcp.bb.pcb_ids_cur: 0
net.inet.tcp.bb.log_auto_all: 0
net.inet.tcp.bb.log_auto_mode: 1
net.inet.tcp.bb.log_auto_ratio: 0
net.inet.tcp.bb.disable_all: 0
net.inet.tcp.bb.log_version: 9
net.inet.tcp.bb.log_id_tcpcb_entries: 0
net.inet.tcp.bb.log_id_tcpcb_limit: 0
net.inet.tcp.bb.log_id_entries: 0
net.inet.tcp.bb.log_id_limit: 0
net.inet.tcp.bb.log_global_entries: 0
net.inet.tcp.bb.log_global_limit: 5000000
net.inet.tcp.bb.log_session_limit: 5000
net.inet.tcp.bb.log_verbose: 0
net.inet.tcp.bb.tp.count: 0
net.inet.tcp.bb.tp.bbmode: 4
net.inet.tcp.bb.tp.number: 0
net.inet.tcp.recvbuf_max: 2097152
net.inet.tcp.recvbuf_auto: 1
net.inet.tcp.insecure_rst: 0
net.inet.tcp.insecure_syn: 0
net.inet.tcp.abc_l_var: 2
net.inet.tcp.rfc3465: 1
net.inet.tcp.initcwnd_segments: 10
net.inet.tcp.rfc3390: 1
net.inet.tcp.rfc3042: 1
net.inet.tcp.newcwv: 0
net.inet.tcp.do_prr: 1
net.inet.tcp.drop_synfin: 0
net.inet.tcp.delayed_ack: 1
net.inet.tcp.blackhole_local: 0
net.inet.tcp.blackhole: 0
net.inet.tcp.log_in_vain: 0
net.inet.tcp.hostcache.purgenow: 0
net.inet.tcp.hostcache.purge: 0
net.inet.tcp.hostcache.prune: 300
net.inet.tcp.hostcache.expire: 3600
net.inet.tcp.hostcache.count: 3
net.inet.tcp.hostcache.bucketlimit: 30
net.inet.tcp.hostcache.hashsize: 512
net.inet.tcp.hostcache.cachelimit: 15360
net.inet.tcp.hostcache.enable: 1
net.inet.tcp.fastopen.server_enable: 0
net.inet.tcp.fastopen.psk_enable: 0
net.inet.tcp.fastopen.path_disable_time: 900
net.inet.tcp.fastopen.numpsks: 0
net.inet.tcp.fastopen.numkeys: 0
net.inet.tcp.fastopen.maxpsks: 2
net.inet.tcp.fastopen.maxkeys: 2
net.inet.tcp.fastopen.keylen: 16
net.inet.tcp.fastopen.client_enable: 1
net.inet.tcp.fastopen.ccache_buckets: 2048
net.inet.tcp.fastopen.ccache_bucket_limit: 16
net.inet.tcp.fastopen.autokey: 120
net.inet.tcp.fastopen.acceptany: 0
net.inet.tcp.ecn.maxretries: 1
net.inet.tcp.ecn.enable: 2
net.inet.tcp.cc.newreno.beta_ecn: 80
net.inet.tcp.cc.newreno.beta: 50
net.inet.tcp.cc.vegas.beta: 3
net.inet.tcp.cc.vegas.alpha: 1
net.inet.tcp.cc.dctcp.ect1: 0
net.inet.tcp.cc.dctcp.slowstart: 0
net.inet.tcp.cc.dctcp.shift_g: 4
net.inet.tcp.cc.dctcp.alpha: 1024
net.inet.tcp.cc.chd.use_max: 1
net.inet.tcp.cc.chd.queue_min: 5
net.inet.tcp.cc.chd.queue_threshold: 20
net.inet.tcp.cc.chd.pmax: 50
net.inet.tcp.cc.chd.loss_fair: 1
net.inet.tcp.cc.cdg.loss_compete_hold_backoff: 5
net.inet.tcp.cc.cdg.loss_compete_consec_cong: 5
net.inet.tcp.cc.cdg.smoothing_factor: 8
net.inet.tcp.cc.cdg.exp_backoff_scale: 3
net.inet.tcp.cc.cdg.beta_loss: 50
net.inet.tcp.cc.cdg.beta_delay: 70
net.inet.tcp.cc.cdg.alpha_inc: 0
net.inet.tcp.cc.cdg.version: 0.1
net.inet.tcp.cc.htcp.rtt_scaling: 0
net.inet.tcp.cc.htcp.adaptive_backoff: 0
net.inet.tcp.cc.abe_frlossreduce: 0
net.inet.tcp.cc.abe: 0
net.inet.tcp.cc.hystartplusplus.bblogs: 0
net.inet.tcp.cc.hystartplusplus.css_rounds: 5
net.inet.tcp.cc.hystartplusplus.css_growth_div: 4
net.inet.tcp.cc.hystartplusplus.n_rttsamples: 8
net.inet.tcp.cc.hystartplusplus.maxrtt_thresh: 16000
net.inet.tcp.cc.hystartplusplus.minrtt_thresh: 4000
net.inet.tcp.cc.available: 
CCmod           D PCB count
cubic           * 21
htcp              0
cdg               0
chd               0
dctcp             0
vegas             0
newreno           0

net.inet.tcp.cc.algorithm: cubic
```
